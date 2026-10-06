//
//  AXTermAppDelegate.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import AppKit
import Combine
import OSLog
import UserNotifications

final class AXTermAppDelegate: NSObject, NSApplicationDelegate {
    var settings: AppSettingsStore?
    let notificationHandler = NotificationActionHandler(router: .shared)
    private var powerSubscriptions: Set<AnyCancellable> = []
    private let launchLog = Logger(subsystem: "AXTerm", category: "Launch")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // What AppKit made of the launch: a default launch with no window
        // here was issue 79's signature.
        let isDefault = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool).map(String.init) ?? "absent"
        launchLog.info("did finish launching: isDefaultLaunch=\(isDefault, privacy: .public) active=\(NSApp.isActive, privacy: .public) windows=\(NSApp.windows.map { $0.identifier?.rawValue ?? "?" }, privacy: .public)")
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

    /// AXTerm opens no documents, so a command-line argument is never a
    /// file to open.
    ///
    /// AppKit treats an argument that does not start with "-" as one, so a
    /// test instance started with `--instance-name "Station A" --callsign
    /// K0EPI` launched as if asked to open the files "Station A" and "K0EPI":
    /// no open-untitled step, nothing it could open, and no window at all
    /// (smoke run 2026-10-03-1, issue 79). Registered in the app's init,
    /// before AppKit reads the arguments.
    static func registerLaunchDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: ["NSTreatUnknownArgumentsAsOpen": false])
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
        // Set before start(): a sleep that arrives first must already be held.
        monitor.sleepPreparation = { [weak self] done in
            MainActor.assumeIsolated {
                guard let self else { return done() }
                self.prepareForSleep(then: done)
            }
        }
        monitor.start()
        monitor.didWake
            .sink { [weak self] wake in
                MainActor.assumeIsolated { self?.resumeAfterSleep(outage: wake.outage) }
            }
            .store(in: &powerSubscriptions)
    }

    /// Say goodbye on the air, then put the radios down deliberately, then
    /// let the machine sleep.
    ///
    /// The same order as quitting, for the same reason: a peer that is told
    /// the session ended stops retransmitting into it. macOS holds the sleep
    /// until `done` (IOKit's system power registration, `SystemPowerMonitor`),
    /// so the DISCs get to settle: the peer's UA or DM, or one T1 with the
    /// DISC on the air. Until 2026-10-06 the radios went down 0.4 s after the
    /// DISCs were handed over, and with AXTerm's own sound modem a DISC still
    /// queued behind a slow key-up never aired (smoke run 2026-10-03-1, issue
    /// 85). Capped by `SystemPowerMonitor.sleepHoldCap`, well inside the 30 s
    /// macOS waits.
    @MainActor
    private func prepareForSleep(then done: @escaping () -> Void) {
        let coordinator = SessionCoordinator.shared
        let discs = coordinator?.prepareForTermination() ?? 0
        let engine = coordinator?.packetEngine
        engine?.appendSystemNotification(
            discs > 0
            ? "Going to sleep. Released \(discs) live session\(discs == 1 ? "" : "s") and put the radios down."
            : "Going to sleep. Radios down until this machine wakes.")

        let releaseRadios = { [weak engine] in
            engine?.radioManager.suspendAll()
            KeepAwakeController.shared.release()
            // A moment for the radios' closing datagrams to leave.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
        }
        guard discs > 0, let coordinator else { return releaseRadios() }
        coordinator.whenTerminationDisconnectsSettle(
            minimum: 0.4, deadline: Date().addingTimeInterval(Self.disconnectWaitCap),
            then: releaseRadios)
    }

    /// Back. Reopen everything that was up, say how long we were gone, and tell
    /// the neighbors — their routes to this station aged while it was away and
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
        // A Mobilinkd link closes by putting the TNC4's own settings back (the
        // ones this radio changed), and those writes need a moment to leave.
        // Without it a TNC4 shared with another radio kept this radio's gains
        // until it was power-cycled.
        let engine = coordinator?.packetEngine
        let restoresTNC4 = (settings?.radios ?? []).contains { engine?.mobilinkdControl(for: $0.id) != nil }
        // A sound-modem radio that AXTerm set up for packet is put back over
        // CI-V as its link closes (after PTT off, before the port shuts; see
        // ModemRadioLink.close). That takes a round trip per setting, so wait
        // for the closes to finish rather than guessing a delay, up to the
        // link's own restore budget plus a margin.
        let restoresRig = radioManager?.hasPreparedRadios ?? false
        // Close the radios once every DISC has settled: the peer's UA or DM,
        // or one T1 with the DISC on the air. A fixed 0.4 s suited a KISS TNC,
        // which keeps a frame it has been handed, but AXTerm's own sound modem
        // still had the DISC queued, and keying an IC-705 through Warbler takes
        // seconds, so no DISC reached the air (smoke run 2026-10-03-1, issue
        // 85). Capped, so a quit never hangs on a link that will not settle.
        let closeRadios = {
            radioManager?.closeAll()
            if restoresRig {
                Self.whenRigsHaveClosed(radioManager, then: replyOnce)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + (restoresTNC4 ? 0.8 : 0.3), execute: replyOnce)
            }
            // Backstop: reply no later than this regardless of how the close goes.
            let backstop: TimeInterval = restoresRig
                ? ModemRadioLink.restoreBudget + 2
                : (restoresTNC4 ? 2.5 : 1.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + backstop, execute: replyOnce)
        }
        let waitUntil = Date().addingTimeInterval(discCount > 0 ? Self.disconnectWaitCap : 0.4)
        if let coordinator {
            coordinator.whenTerminationDisconnectsSettle(minimum: 0.4, deadline: waitUntil, then: closeRadios)
        } else {
            closeRadios()
        }
        return .terminateLater
    }

    /// The longest a quit waits for its DISCs to settle before closing the
    /// radios anyway. One T1 on a slow path plus a slow key-up fits well
    /// inside it; the peer times out any link still up, as before.
    static let disconnectWaitCap: TimeInterval = 12

    /// Call `done` once no link is still closing, checking every tenth of a
    /// second, then a short moment more for the last datagrams to leave.
    private static func whenRigsHaveClosed(_ radioManager: RadioManager?, then done: @escaping () -> Void) {
        guard let radioManager, radioManager.isClosingRigs else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            whenRigsHaveClosed(radioManager, then: done)
        }
    }
}
