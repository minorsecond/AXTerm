import Foundation
import Combine

#if os(iOS)
import UIKit
#endif

/// Keeping the screen — and therefore the app — alive on a handheld.
///
/// This is not a convenience. On iOS the display sleeping is the first step
/// toward the app being suspended, and a suspended app loses its TCP
/// connection to the TNC. Mid-exchange that costs a partial Winlink transfer
/// and a session the gateway has to time out; mid-listen it means an armed
/// P2P station silently stops answering.
///
/// It is also a battery cost, on a device that may be the operator's only
/// light source at the end of an activation. So it is a graded choice rather
/// than a switch, and the default holds the screen only when something would
/// actually break.
nonisolated enum KeepAwakePolicy: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Let the device sleep normally.
    case never
    /// Hold the screen only while an exchange or transfer is running.
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
        switch self {
        case .never:
            "The device sleeps as usual. A Winlink exchange or file transfer that is running when it sleeps will be interrupted — iOS suspends the app and the connection to the TNC drops."
        case .duringTransfers:
            "The screen stays on while a Winlink exchange, a file transfer, or an armed peer-to-peer listener is running, and sleeps normally the rest of the time. This is the setting that protects what would actually break."
        case .whileConnected:
            "The screen stays on for as long as the app is connected to a TNC. Use it when the device is on power and acting as a station; it will flatten a battery over an afternoon."
        }
    }

    /// Whether this policy holds the screen given what the station is doing.
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

/// Applies the policy to the device.
///
/// Platform-guarded rather than absent on macOS: a Mac's display sleeping
/// does not suspend the app or drop its sockets, so there is nothing to hold
/// and the setting is not offered there.
@MainActor
final class KeepAwakeController: ObservableObject {

    @Published private(set) var isHoldingAwake = false

    /// Why the screen is being held, for the indicator.
    @Published private(set) var reason: String?

    /// Re-evaluates and applies.
    func update(policy: KeepAwakePolicy,
                isConnected: Bool,
                isTransferring: Bool,
                isListening: Bool) {
        let shouldHold = policy.shouldHoldAwake(
            isConnected: isConnected, isTransferring: isTransferring, isListening: isListening)

        reason = shouldHold ? Self.reasonText(
            isTransferring: isTransferring, isListening: isListening,
            isConnected: isConnected) : nil

        guard shouldHold != isHoldingAwake else { return }
        isHoldingAwake = shouldHold
        Self.apply(shouldHold)
    }

    /// Releases the hold. Called when the app leaves the foreground, because
    /// a backgrounded app has no business keeping the display on and iOS
    /// ignores the flag there anyway — leaving it set would only confuse the
    /// next foreground pass.
    func release() {
        guard isHoldingAwake else { return }
        isHoldingAwake = false
        reason = nil
        Self.apply(false)
    }

    /// Pure text, so it can be tested without touching the main actor.
    nonisolated static func reasonText(isTransferring: Bool, isListening: Bool,
                                       isConnected: Bool) -> String {
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
    }

    private static func apply(_ hold: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = hold
        #endif
    }

    /// Whether the setting is worth showing at all.
    ///
    /// A Mac's display sleeping does not suspend the app or drop its sockets,
    /// so there is nothing here to configure.
    nonisolated static var isSupported: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
}
