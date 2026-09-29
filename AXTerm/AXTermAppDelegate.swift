//
//  AXTermAppDelegate.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import AppKit
import Combine
import UserNotifications

final class AXTermAppDelegate: NSObject, NSApplicationDelegate {
    var settings: AppSettingsStore?
    let notificationHandler = NotificationActionHandler(router: .shared)
    private var powerSubscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notificationHandler
        watchForSleep()
        // The unit-test host must not flash a window or steal focus:
        // stay a background process and put away anything SwiftUI
        // already ordered in. UI tests keep the real app.
        // .accessory, not .prohibited: the harder policy interferes
        // with XCTest's runner bootstrap on some clones.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows { window.orderOut(nil) }
        }
    }

    /// Sleep and wake, handled here rather than in a view.
    ///
    /// `ContentView` used to own the whole of this, which was fine until "Show
    /// icon in Menu Bar" — close the window and the view is torn down while
    /// the station keeps running, so the machine could go to sleep with live
    /// sessions on the air and nobody left to release them. The delegate lives
    /// as long as the process does.
    ///
    /// The view still handles what is genuinely its own: the mailbox goodbye,
    /// the service address table, and the keep-awake indicator.
    private func watchForSleep() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let monitor = SystemPowerMonitor.shared
        monitor.start()
        monitor.willSleep
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.prepareForSleep() } }
            .store(in: &powerSubscriptions)
        monitor.didWake
            .sink { [weak self] wake in
                MainActor.assumeIsolated { self?.resumeAfterSleep(outage: wake.outage) }
            }
            .store(in: &powerSubscriptions)
    }

    /// Say goodbye on the air, then put the radios down deliberately.
    ///
    /// The same order `applicationShouldTerminate` uses below, and for the same
    /// reason: a peer that is told the session ended stops retransmitting into
    /// it. The DISCs are transmitted and not waited on. A UA needs a round trip
    /// over a radio link and there is no waiting for one on a machine that is
    /// about to stop executing; macOS's window here is short and not
    /// guaranteed. A lost DISC still leaves the peer to time out, and nothing
    /// on this side can fix that.
    @MainActor
    private func prepareForSleep() {
        let coordinator = SessionCoordinator.shared
        let discs = coordinator?.prepareForTermination() ?? 0
        let engine = coordinator?.packetEngine
        engine?.appendSystemNotification(
            discs > 0
            ? "Going to sleep. Released \(discs) live session\(discs == 1 ? "" : "s") and put the radios down."
            : "Going to sleep. Radios down until this machine wakes.")

        // The same grace `applicationShouldTerminate` takes, for the same
        // reason: `prepareForTermination` hands the DISCs to the link, and
        // tearing the socket down in the next statement would cancel them
        // before a byte left. Suspending immediately is worse than a delay
        // that may not get its turn — one guarantees the peer is never told.
        //
        // Best-effort, and knowingly so. macOS's window after
        // `willSleepNotification` is short and not promised, and this does not
        // block in it. A DISC that does not make it out leaves the peer to
        // time out, which is where we were before.
        let releaseRadios = { [weak engine] in engine?.radioManager.suspendAll() }
        if discs > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { releaseRadios() }
        } else {
            releaseRadios()
        }
        KeepAwakeController.shared.release()
    }

    /// Back. Reopen everything that was up, say how long we were gone, and tell
    /// the neighbours — their routes to this station aged while it was away and
    /// the steady NODES cadence can be an hour.
    @MainActor
    private func resumeAfterSleep(outage: TimeInterval?) {
        let monitor = SystemPowerMonitor.shared
        let coordinator = SessionCoordinator.shared
        let engine = coordinator?.packetEngine
        if let outage, outage > 60, let from = monitor.sleptAt, let to = monitor.wokeAt {
            // Stated as a fact rather than left to be inferred from a hole in
            // the timestamps. A node operator reading this at breakfast should
            // not have to work out how long their station was gone.
            engine?.appendSystemNotification(PowerInterruption.outageSummary(from: from, to: to))
        }
        engine?.radioManager.resumeAll()
        coordinator?.announceAfterWake()
        KeepAwakeController.shared.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The test host hides its window; that must never read as "quit".
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        guard let settings else { return false }
        return !settings.runInMenuBar
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Graceful link teardown: DISC every live session so peers drop their
        // side immediately instead of polling a zombie until their retry limit
        // exhausts. Without this, quitting mid-session simply vanished — the
        // peer kept the link "up" for minutes (observed with KB5YZB-7's node
        // retransmitting stale session data at our fresh SABMs).
        let coordinator = SessionCoordinator.shared
        let discCount = coordinator?.prepareForTermination() ?? 0
        let radioManager = coordinator?.packetEngine?.radioManager
        let anyConnected = radioManager?.radioStates.values.contains(.connected) ?? false
        guard discCount > 0 || anyConnected else { return .terminateNow }
        // Brief grace so DISC bytes flush through the KISS link before the
        // process dies, THEN release the radio links so the IC-705's LAN slot,
        // PTT and audio are freed at quit instead of being held until the radio
        // times them out — a held slot was why the next launch's reconnect had
        // to be retried. A final short moment lets the Icom token-release
        // datagrams leave before the sockets die with the process.
        // reply(toApplicationShouldTerminate:) must land exactly once, and it
        // must land even if a link's close stalls — otherwise the app sits in
        // .terminateLater until macOS force-kills it (SIGTERM). A one-shot
        // guard plus an absolute fallback deadline guarantee the quit always
        // completes; whichever timer fires first wins, the other is a no-op.
        var replied = false
        let replyOnce: () -> Void = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            radioManager?.closeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: replyOnce)
        }
        // Backstop: reply no later than this regardless of how the close goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: replyOnce)
        return .terminateLater
    }
}
