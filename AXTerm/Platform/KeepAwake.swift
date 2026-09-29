import Foundation
import Combine

#if os(iOS)
import UIKit
#endif

/// Keeping the station's links alive while nobody is looking at the screen.
///
/// Two platforms, two different failures, one setting.
///
/// On iOS the display sleeping is the first step toward the app being
/// suspended, and a suspended app loses its TCP connection to the TNC. Mid
/// exchange that costs a partial Winlink transfer and a session the gateway
/// has to time out; mid-listen it means an armed P2P station silently stops
/// answering.
///
/// On macOS the app is not suspended, it is napped, and for a long time this
/// file said that meant there was nothing to hold. The night of 2026-09-18
/// settled that. The Mac never slept — other processes held system sleep off
/// all night — but the display slept at 19:50:07 and App Nap coalesced the
/// app's timers into roughly half-hour batches. The IC-705's LAN session
/// stopped getting its keepalives and the radio dropped it; the KISS socket to
/// Direwolf stopped being read promptly and the far end reset it. The station
/// was off the air for eight hours. Every time the display came back on the
/// links recovered within a second or two, four times out of four, which is
/// what made the cause legible at all.
///
/// So the app now asks macOS for two separate things. Staying *scheduled* is
/// not a preference and is not offered as one: an app holding open radio links
/// should never be napped, it costs the operator nothing, and it does not keep
/// the Mac awake. Holding off idle system sleep is the preference, because it
/// really does cost battery.
///
/// Neither one touches display sleep. There is no reason to hold a screen on
/// to run a node, and this deliberately does not.
nonisolated enum KeepAwakePolicy: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Let the machine sleep normally.
    case never
    /// Hold it only while an exchange or transfer is running.
    case duringTransfers
    /// Hold it whenever there is a live connection to the TNC.
    case whileConnected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .duringTransfers: "During transfers"
        case .whileConnected: "While connected"
        }
    }

    var detail: String {
        #if os(macOS)
        switch self {
        case .never:
            "This Mac sleeps as usual. A Winlink exchange or file transfer that is running when it sleeps will be interrupted, and every radio link drops until it wakes."
        case .duringTransfers:
            "This Mac stays awake while a Winlink exchange, a file transfer, or an armed peer-to-peer listener is running, and sleeps normally the rest of the time. The display sleeps either way."
        case .whileConnected:
            "This Mac stays awake for as long as a radio is connected, which is what a station left running overnight needs. The display still sleeps. On battery this will drain it, and closing the lid sleeps the Mac whatever this is set to."
        }
        #else
        switch self {
        case .never:
            "The device sleeps as usual. A Winlink exchange or file transfer that is running when it sleeps will be interrupted — iOS suspends the app and the connection to the TNC drops."
        case .duringTransfers:
            "The screen stays on while a Winlink exchange, a file transfer, or an armed peer-to-peer listener is running, and sleeps normally the rest of the time. This is the setting that protects what would actually break."
        case .whileConnected:
            "The screen stays on for as long as the app is connected to a TNC. Use it when the device is on power and acting as a station; it will flatten a battery over an afternoon."
        }
        #endif
    }

    /// Whether this policy holds off sleep given what the station is doing.
    func shouldHoldAwake(isConnected: Bool, isTransferring: Bool, isListening: Bool) -> Bool {
        switch self {
        case .never:
            return false
        case .duringTransfers:
            // A listener counts: an armed station that sleeps stops answering
            // calls, and nobody finds out until somebody fails to reach it.
            return isTransferring || isListening
        case .whileConnected:
            return isConnected
        }
    }
}

/// What the app is currently asking the OS for.
///
/// Separate from the policy because the weaker of the two holds is not the
/// operator's decision. Anything live at all earns `scheduling`; only the
/// policy earns `schedulingAndAwake`.
nonisolated enum KeepAwakeHold: String, Equatable, Sendable, CaseIterable {
    /// Nothing live. The OS does as it likes.
    case none
    /// Stay scheduled — no App Nap, no coalesced timers — but let an idle
    /// machine sleep if the operator has not asked otherwise.
    case scheduling
    /// Stay scheduled *and* hold off idle system sleep. The display is free to
    /// sleep in both cases.
    case schedulingAndAwake
}

/// Applies the policy to the machine.
@MainActor
final class KeepAwakeController: ObservableObject {

    /// The app's one controller on macOS.
    ///
    /// Shared rather than owned by a view because with "Show icon in Menu Bar"
    /// on, closing the window tears the view down while the station keeps
    /// running — which is exactly the case where being napped hurts most. A
    /// hold that lived in `ContentView` would be released at the moment it
    /// started to matter.
    static let shared = KeepAwakeController()

    /// The operator's setting, remembered so anything that notices the station's
    /// work change can re-evaluate without knowing about preferences.
    var policy: KeepAwakePolicy = .duringTransfers {
        didSet { if policy != oldValue { refresh() } }
    }

    /// What the station is doing, as last reported.
    private var isConnected = false
    private var isTransferring = false
    private var isListening = false

    /// What is being held right now.
    @Published private(set) var hold: KeepAwakeHold = .none

    /// Whether sleep itself is being held off, which is the part worth showing
    /// an indicator for. Staying scheduled is invisible and should be.
    @Published private(set) var isHoldingAwake = false

    /// Why sleep is being held, for the indicator.
    @Published private(set) var reason: String?

    #if os(macOS)
    /// The live `beginActivity` token, if any. Ending it is what releases the
    /// hold; dropping it on the floor would leak the assertion for the life of
    /// the process.
    private var activity: NSObjectProtocol?
    #endif

    /// What the app should be asking for, given the policy and what the
    /// station is doing. Pure, so the table can be tested without a machine
    /// to put to sleep.
    nonisolated static func hold(policy: KeepAwakePolicy,
                                 isConnected: Bool,
                                 isTransferring: Bool,
                                 isListening: Bool) -> KeepAwakeHold {
        // Nothing live: ask for nothing. An idle AXTerm has no business
        // pinning a Mac's scheduler, let alone its power state.
        guard isConnected || isTransferring || isListening else { return .none }
        return policy.shouldHoldAwake(isConnected: isConnected,
                                      isTransferring: isTransferring,
                                      isListening: isListening)
            ? .schedulingAndAwake
            : .scheduling
    }

    /// Re-evaluates and applies.
    func update(policy: KeepAwakePolicy,
                isConnected: Bool,
                isTransferring: Bool,
                isListening: Bool) {
        self.isConnected = isConnected
        self.isTransferring = isTransferring
        self.isListening = isListening
        // Assigned directly rather than through `policy`, whose observer would
        // call `refresh()` a second time for the same change.
        if self.policy != policy { self.policy = policy } else { refresh() }
    }

    /// A link came up or went down. Enough on its own: the other two inputs
    /// are remembered, so a station whose window has been closed still gets
    /// its hold right when a radio connects or drops.
    func connectionChanged(isConnected: Bool) {
        guard self.isConnected != isConnected else { return }
        self.isConnected = isConnected
        refresh()
    }

    /// Re-applies from what is currently known.
    func refresh() {
        let next = Self.hold(policy: policy, isConnected: isConnected,
                             isTransferring: isTransferring, isListening: isListening)

        isHoldingAwake = next == .schedulingAndAwake
        reason = isHoldingAwake ? Self.reasonText(
            isTransferring: isTransferring, isListening: isListening,
            isConnected: isConnected) : nil

        guard next != hold else { return }
        hold = next
        apply(next)
    }

    /// Releases everything. Called when the app leaves the foreground on iOS,
    /// because a backgrounded app has no business keeping the display on and
    /// iOS ignores the flag there anyway, and before the Mac sleeps, because
    /// an assertion outliving the thing it was protecting is just a leak.
    func release() {
        reason = nil
        isHoldingAwake = false
        guard hold != .none else { return }
        hold = .none
        apply(.none)
    }

    /// Pure text, so it can be tested without touching the main actor.
    nonisolated static func reasonText(isTransferring: Bool, isListening: Bool,
                                       isConnected: Bool) -> String {
        #if os(macOS)
        if isTransferring {
            return "Sleep held off: a transfer is running. Letting this Mac sleep would drop the connection part-way through."
        }
        if isListening {
            return "Sleep held off: this station is armed to answer peer-to-peer calls. A sleeping Mac stops answering, and nobody finds out until somebody fails to reach it."
        }
        if isConnected {
            return "Sleep held off: a radio is connected. The display still sleeps; on battery this will drain it noticeably, and closing the lid sleeps the Mac regardless."
        }
        return "Sleep held off."
        #else
        if isTransferring {
            return "Screen held on: a transfer is running. Letting the device sleep would suspend the app and drop the connection part-way through."
        }
        if isListening {
            return "Screen held on: this station is armed to answer peer-to-peer calls. A sleeping device stops answering, and nobody finds out until somebody fails to reach it."
        }
        if isConnected {
            return "Screen held on: connected to a TNC. This will use the battery noticeably — see Settings if the device is not on power."
        }
        return "Screen held on."
        #endif
    }

    private func apply(_ hold: KeepAwakeHold) {
        #if os(macOS)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        switch hold {
        case .none:
            break
        case .scheduling:
            // Defeats App Nap and leaves idle system sleep alone. This is the
            // one that would have saved 2026-09-18.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: Self.activityReason)
        case .schedulingAndAwake:
            // `.userInitiated` is `.userInitiatedAllowingIdleSystemSleep` plus
            // `idleSystemSleepDisabled`, which is exactly the difference the
            // operator is choosing. Neither spelling touches display sleep.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: Self.activityReason)
        }
        #elseif os(iOS)
        UIApplication.shared.isIdleTimerDisabled = hold == .schedulingAndAwake
        #endif
    }

    #if os(macOS)
    /// Ends the activity explicitly rather than trusting the token's
    /// deallocation to do it.
    ///
    /// `shared` never reaches here, so this is for any other instance — the
    /// tests build their own, and nothing stops a future caller doing the
    /// same. A leaked assertion is the kind of bug that only shows up later as
    /// somebody's Mac refusing to sleep, with nothing on screen to say why.
    nonisolated deinit {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
    #endif

    /// Shown against the process in `pmset -g assertions`, so an operator
    /// working out why their Mac will not sleep can see who is asking.
    private static let activityReason = "AXTerm is carrying radio links"

    /// Whether the setting is worth showing at all.
    ///
    /// True everywhere now. It was false on macOS on the theory that a Mac's
    /// display sleeping does not drop its sockets; see the note at the top of
    /// this file for the night that disproved it.
    nonisolated static var isSupported: Bool { true }
}
