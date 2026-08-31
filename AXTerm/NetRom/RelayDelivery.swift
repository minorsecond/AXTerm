import Foundation

/// How far a sent message has demonstrably got.
///
/// A node-prompt relay is character streaming through connected nodes, and
/// the evidence available about a message in flight is thinner than the
/// picture of the chain suggests:
///
/// * **AX.25 acknowledges one hop.** `RR(nr:5)` from DRLNOD means DRLNOD has
///   the bytes. It says nothing about KB5YZB-7, COSCO or the destination —
///   those stations acknowledge nothing to *us*, because the chain carries no
///   end-to-end receipt.
/// * **A reply is proof of arrival.** When the far end answers, it answered
///   something, and that something reached it.
///
/// Two states, both earned. Lighting up the middle hops as a message
/// "travels" through them would be a picture of nothing — the app cannot see
/// those hops, and pretending otherwise is the kind of confident wrongness
/// that costs an operator a real decision about whether traffic got through.
nonisolated struct RelayDelivery: Equatable, Sendable {

    enum State: Equatable, Sendable {
        /// Nothing sent on this link yet.
        case idle
        /// Handed to the radio; the next hop has not acknowledged it.
        case inFlight
        /// The next hop acknowledged the frame. On a chain that is the only
        /// hop we can see; on a direct link it is arrival.
        case atFirstHop
        /// The far end replied, which it could only do having received it.
        case answered
    }

    /// The station this link actually terminates at — the one whose acks we
    /// can read.
    let firstHop: String
    /// Where the message is ultimately headed. Equal to `firstHop` on a
    /// direct connection.
    let destination: String

    private(set) var state: State = .idle
    /// What was sent, for the tooltip. Trimmed by the caller.
    private(set) var text: String?
    private(set) var sentAt: Date?

    init(firstHop: String, destination: String) {
        self.firstHop = firstHop.uppercased()
        self.destination = destination.uppercased()
    }

    var isRelayed: Bool { firstHop != destination }

    /// A new message replaces the last one: this reports on the message the
    /// operator is currently wondering about, not a history.
    mutating func sent(_ text: String, at when: Date) {
        self.text = text
        self.sentAt = when
        state = .inFlight
    }

    mutating func acknowledgedByFirstHop(at when: Date) {
        // Evidence only ever moves forward. On a slow path the link-layer ack
        // can land after the reply it triggered, and that must not walk the
        // state back to something weaker than what is already proven.
        guard state == .inFlight else { return }
        state = .atFirstHop
    }

    mutating func answered(at when: Date) {
        guard state == .inFlight || state == .atFirstHop else { return }
        state = .answered
    }

    /// One line for the status strip. Nil when there is nothing to report.
    var summary: String? {
        switch state {
        case .idle:
            return nil
        case .inFlight:
            return "Sending…"
        case .atFirstHop:
            // On a direct link the first hop *is* the destination, and
            // "at DRLNOD · awaiting DRLNOD" would be nonsense.
            return isRelayed ? "At \(firstHop) · awaiting \(destination)"
                             : "Delivered to \(firstHop)"
        case .answered:
            return "Answered by \(destination)"
        }
    }

    /// The longer form, which says why the app cannot claim more.
    var detail: String? {
        switch state {
        case .idle:
            return nil
        case .inFlight:
            return "Handed to the radio; \(firstHop) has not acknowledged it yet."
        case .atFirstHop where isRelayed:
            return "\(firstHop) acknowledged the frame — that is the only hop AX.25 "
                + "acknowledges. The nodes between here and \(destination) send no "
                + "receipt, so there is nothing further to report until "
                + "\(destination) replies."
        case .atFirstHop:
            return "\(firstHop) acknowledged the frame."
        case .answered:
            return "\(destination) replied, so it received this."
        }
    }
}
