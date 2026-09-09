import Foundation

/// One APRS message-class exchange, persisted. Incoming and outgoing text
/// messages, bulletins, queries, and the delivery state of an outgoing message
/// (queued → sent → acked/failed) all live in this one flat record, mirroring
/// the BBS mailbox's single-struct shape. Acks are tracked with a nullable
/// timestamp and a retry cursor, the way BBS tracks read/kill.
nonisolated struct APRSMessageRecord: Identifiable, Equatable, Sendable {

    /// Which way the message travelled.
    enum Direction: String, Codable, Sendable { case incoming, outgoing }

    /// What kind of message-class frame this is.
    enum Kind: String, Codable, Sendable {
        case message    // person-to-person text
        case bulletin   // BLN… broadcast, read-only
        case query      // a directed query we sent or received (?APRSP …)
    }

    /// Delivery state. Only outgoing numbered messages move past `.sent`.
    enum State: String, Codable, Sendable {
        case received   // incoming: nothing to deliver
        case queued     // outgoing: not yet on the air
        case sent       // outgoing: transmitted, awaiting ack (if numbered)
        case acked      // outgoing: acknowledged by the addressee
        case failed     // outgoing: gave up after the retry budget
    }

    var id: String
    var direction: Direction
    var kind: Kind
    /// Our own call+SSID on this exchange (which radio identity sent/received).
    var localCall: String
    /// The other station's call+SSID — the conversation/thread key.
    var peer: String
    var text: String
    /// The APRS message number, present when an ack is expected/carried.
    var number: String?
    /// Raw `RadioID` the exchange used, so a reply/ack goes out the same radio.
    var radioID: String?
    /// The digipeater path the message uses, so a retry repeats the same route.
    var path: [String]
    /// Incoming only: heard with an empty digipeater path (a direct copy).
    /// Feeds the "who can hear me" reachability picture.
    var viaDirect: Bool
    /// Sent-at for outgoing, received-at for incoming.
    var createdAt: Date
    var state: State
    var ackedAt: Date?
    /// Transmit attempts made for an outgoing message (for the retry ladder).
    var attempts: Int
    /// When the next retransmit is due; nil when nothing is pending.
    var nextRetryAt: Date?
    var isRead: Bool

    init(id: String = UUID().uuidString,
         direction: Direction,
         kind: Kind,
         localCall: String,
         peer: String,
         text: String,
         number: String? = nil,
         radioID: String? = nil,
         path: [String] = [],
         viaDirect: Bool = false,
         createdAt: Date,
         state: State,
         ackedAt: Date? = nil,
         attempts: Int = 0,
         nextRetryAt: Date? = nil,
         isRead: Bool = false) {
        self.id = id
        self.direction = direction
        self.kind = kind
        self.localCall = localCall
        self.peer = peer
        self.text = text
        self.number = number
        self.radioID = radioID
        self.path = path
        self.viaDirect = viaDirect
        self.createdAt = createdAt
        self.state = state
        self.ackedAt = ackedAt
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.isRead = isRead
    }
}
