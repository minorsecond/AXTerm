import Foundation

/// Detects user-initiated NET/ROM relay commands and node responses in a connected session.
///
/// When a user connects to a NET/ROM node (e.g. DRLNOD) and manually types "C KB5YZB-7",
/// this detector tracks the pending relay and confirms it when the node responds "###LINK MADE."
///
/// State transitions:
///   idle → pending  : outgoing "C <callsign>" detected
///   pending → established : incoming "###LINK MADE." received
///   pending → idle   : incoming "###LINK FAILED" or "ENTER COMMAND" received
///   established → pending : outgoing "C <callsign>" again (chained relay)
///   established → idle : incoming "ENTER COMMAND" received (back at node prompt)
///   any → idle       : clear() called (on L2 disconnect)
nonisolated struct ManualRelayDetector {

    enum State: Equatable {
        case idle
        case pending(destination: String)
        case established(destination: String)
    }

    private(set) var state: State = .idle

    /// Whether a node prompt has already gone past on this link.
    ///
    /// A node greets once per connection, so a relay armed after the
    /// greeting is waiting for something that will never arrive. This is
    /// what lets the arming decision tell "the banner is still to come"
    /// from "the banner is spent" — see `NetRomRelayLifecycle.armingAction`.
    /// Cleared with the rest of the state when the link drops, because the
    /// next connection greets afresh.
    private(set) var hasSeenNodePrompt = false

    /// Returns the confirmed relay destination, or nil when not yet established.
    var activeRelayDestination: String? {
        if case .established(let dest) = state { return dest }
        return nil
    }

    /// Process a line of text the user is about to send over the session.
    /// Returns the updated state.
    @discardableResult
    mutating func processOutgoing(_ rawText: String) -> State {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dest = Self.parseConnectCommand(text) {
            state = .pending(destination: dest)
        }
        return state
    }

    /// Process a complete line received from the remote node.
    /// Returns the updated state.
    @discardableResult
    mutating func processIncoming(_ rawText: String) -> State {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isNodePrompt(text) { hasSeenNodePrompt = true }
        switch state {
        case .pending(let destination):
            if Self.isLinkMade(text) {
                state = .established(destination: destination)
            } else if Self.isLinkFailed(text) || Self.isRelayCleared(text) {
                state = .idle
            }
        case .established:
            if Self.isRelayCleared(text) {
                state = .idle
            }
        case .idle:
            break
        }
        return state
    }

    /// Reset to idle (call on L2 session disconnect or explicit user cancellation).
    mutating func clear() {
        state = .idle
        hasSeenNodePrompt = false
    }

    // MARK: - Pattern matchers

    /// Parses "C <callsign>" (NET/ROM connect command) from trimmed text.
    /// Returns the uppercased callsign, or nil if the text is not a valid C command.
    static func parseConnectCommand(_ trimmed: String) -> String? {
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = connectCommandRegex.firstMatch(in: trimmed, range: range),
              let callRange = Range(match.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[callRange]).uppercased()
    }

    // Compiled once — NSRegularExpression is expensive to recompile per-call.
    private static let connectCommandRegex: NSRegularExpression = {
        // 'C' or 'c', one or more spaces, then a valid AX.25 callsign (1–6 chars + optional SSID 0–15)
        try! NSRegularExpression(pattern: #"^[Cc]\s+([A-Za-z0-9]{1,6}(?:-(?:[0-9]|1[0-5]))?)$"#)
    }()

    static func isLinkMade(_ text: String) -> Bool {
        text.uppercased().contains("###LINK MADE")
    }

    static func isLinkFailed(_ text: String) -> Bool {
        text.uppercased().contains("###LINK FAILED")
    }

    /// True when the node is showing its command prompt.
    ///
    /// Narrower than `isRelayCleared` on purpose: that also treats a
    /// disconnect notice as ending a relay, and a disconnect is not a
    /// prompt. Recording one as a prompt would tell the arming decision the
    /// greeting is spent when the node has yet to say anything.
    static func isNodePrompt(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper.contains("ENTER COMMAND") || upper.contains("ENTER CMD")
    }

    /// True when the node signals relay teardown: back at the command prompt, or remote disconnected.
    static func isRelayCleared(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper.contains("ENTER COMMAND")
            || upper.contains("ENTER CMD")
            || upper.contains("###DISCONNECTED FROM")
    }
}
