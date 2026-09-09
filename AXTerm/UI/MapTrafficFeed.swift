import Foundation
import Combine

/// Which radios' traffic a strip is showing.
///
/// Separate and pure because the rule is the whole point of the feature and
/// is easy to get subtly wrong: a station running an APRS radio and a packet
/// radio watches one channel at a time, and a strip that quietly mixes the
/// other radio's frames in is worse than no strip — it attributes traffic to
/// a channel it never appeared on.
nonisolated enum MapTrafficScope {

    /// Whether one line belongs in the current view.
    ///
    /// - Parameters:
    ///   - radio: the radio the frame arrived on (or was sent from); nil for
    ///     a frame logged before radios were attributed.
    ///   - selected: the radio whose tab is showing; nil means every visible
    ///     radio at once.
    ///   - visible: the radios the operator has enabled and not hidden.
    static func shows(radio: RadioID?, selected: RadioID?, visible: Set<RadioID>) -> Bool {
        if let selected { return radio == selected }
        // An unattributed frame is shown rather than dropped: on a
        // single-radio station there is only one channel it can have come
        // from, and dropping it would empty the strip for no gain.
        guard let radio else { return true }
        guard !visible.isEmpty else { return true }
        return visible.contains(radio)
    }
}

/// Whether a frame on a shared channel is addressed to this station.
///
/// Two different questions wear the same words on packet radio, and the strip
/// needs both: an AX.25 frame carries the addressee in its destination field,
/// while an APRS message carries it in the payload — the AX.25 destination
/// there is a tocall like `APZAXT` that names the *software*, not the
/// recipient. Answering only the first missed every message anyone ever sent
/// us over APRS.
///
/// Broadcasts are deliberately not "for us": a bulletin (`BLN…`) and a general
/// query go to everyone, and tinting them would tint most of the channel.
nonisolated enum TrafficAddressing {

    /// - Parameters:
    ///   - destinationAnswered: the session layer answers the frame's AX.25
    ///     destination — our callsign, another radio's, or a service SSID.
    ///   - info: the information field, for the APRS addressee.
    ///   - ours: every callsign this station answers to, as displayed.
    static func isForUs(destinationAnswered: Bool, info: Data, ours: [String]) -> Bool {
        if destinationAnswered { return true }
        switch APRSMessage.parse(info: info) {
        case let .message(addressee, _, _),
             let .ack(addressee, _),
             let .reject(addressee, _),
             let .directedQuery(addressee, _):
            return APRSMessage.isAddressedToUs(addressee, ours: ours)
        case .bulletin, .generalQuery, .none:
            return false
        }
    }
}

/// The last few frames on the air, for the map's traffic strip.
///
/// Its own object rather than a slice of `PacketEngine.packets` read by the
/// map, and that is the whole point. The map view is expensive — it rebuilds
/// annotations, overlays and tracks — and the packet array changes on every
/// frame, several times a second on a busy channel. A view that observes the
/// engine directly re-renders the map for traffic it does not draw. This
/// republishes a short, already-formatted list, so only the strip that shows
/// it is invalidated; the map holds the feed as a plain reference and never
/// observes it.
///
/// **Both directions.** Received frames come from the engine's log; our own
/// transmissions never reach that log — they are written straight to the
/// console — so they arrive here separately through `record`, and the two are
/// merged by time. A strip that showed only what other stations said left the
/// operator unable to tell a beacon that went out from one that did not.
@MainActor
final class MapTrafficFeed: ObservableObject {

    /// Where one of our own frames has got to.
    ///
    /// "Sent" is two events, and the strip used to show only the first. A
    /// frame is handed to the radio immediately; it goes on the air when the
    /// channel is clear and the transmitter keys, which on a busy channel is
    /// seconds later and sometimes never — the modem gives up after
    /// `maxChannelWaitSeconds` and discards what it was holding. An operator
    /// watching a query go out has no way to tell those apart from a line
    /// that appears the instant they click.
    ///
    /// Only the built-in modem can report this. A hardware TNC accepts KISS
    /// bytes and says nothing further, so for those radios there is nothing
    /// to promise and the state stays nil.
    enum TransmitState: Equatable, Sendable {
        /// Handed to the radio, not yet keyed.
        case pending
        /// The transmitter keyed and released: it went out.
        case onAir
        /// The radio gave up — the channel never cleared, or PTT was refused.
        case dropped
    }

    /// One frame, reduced to what a single line can show.
    struct Line: Identifiable, Equatable {
        let id: UUID
        var at: Date
        var from: String
        var to: String
        /// Digipeaters the frame came through, already joined; empty for a
        /// frame heard direct.
        var via: String
        /// What it said, trimmed to a line — an APRS comment, a beacon text,
        /// or the frame type when there is nothing printable.
        var summary: String
        /// True for a frame this station transmitted, so the operator's own
        /// traffic reads apart from everyone else's.
        var isOurs: Bool
        /// True for a frame addressed to this station — an AX.25 frame to one
        /// of our addresses, or an APRS message to our callsign. The one line
        /// in a scrolling channel that wants an answer.
        var isForUs: Bool = false
        /// The radio it arrived on, or went out on. Nil for a frame with no
        /// radio attribution.
        var radio: RadioID?
        /// For our own frames on a radio that can report keying: whether it
        /// has actually gone out. Nil for everything else.
        var transmit: TransmitState?
    }

    /// What the app knows about a packet that the feed cannot work out for
    /// itself: whether it is ours, and whether it is addressed to us. Both
    /// depend on the station's registered addresses, which live in the
    /// session layer.
    struct Attribution {
        var isOurs: Bool
        var isForUs: Bool

        init(isOurs: Bool, isForUs: Bool) {
            self.isOurs = isOurs
            self.isForUs = isForUs
        }
    }

    /// How many lines one radio's view shows. A strip a few rows tall with a
    /// little scrollback — this is a glance, not the Packets page.
    static let capacity = 60
    /// How many are kept across all radios, so switching tabs does not start
    /// from an empty strip.
    static let bufferCapacity = 300

    /// Explicit nonisolated deinit: an implicitly MainActor-isolated class
    /// gets an isolated deallocating deinit, which aborts in libmalloc under
    /// the test runner on this toolchain. The same note is on
    /// `AdaptiveStatusStore` and `PingProber`, for the same reason.
    nonisolated deinit {}

    @Published private(set) var lines: [Line] = []

    /// Kept apart so a new batch of received frames does not discard the
    /// transmissions merged in between them.
    private var received: [Line] = []
    private var sent: [Line] = []

    private var cancellable: AnyCancellable?

    /// Follow an engine's packets. Only the newest arrivals are formatted, so
    /// the cost per frame is one line, not a re-scan of the whole log.
    func follow(_ packets: Published<[Packet]>.Publisher,
                attribution: @escaping @MainActor (Packet) -> Attribution) {
        cancellable = packets
            // The map does not need to be current to the millisecond, and a
            // burst of frames arriving together should cost one update, not
            // twenty.
            .throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] all in
                guard let self else { return }
                self.absorb(all, attribution: attribution)
            }
    }

    /// Rebuild the received tail from the engine's log.
    ///
    /// Takes the last `bufferCapacity` packets rather than diffing: the
    /// engine's array is capped and reordered by its own retention, so a diff
    /// would have to track identity across trims for no gain at this size.
    func absorb(_ packets: [Packet], attribution: @MainActor (Packet) -> Attribution) {
        received = packets.suffix(Self.bufferCapacity).map { packet in
            let marks = attribution(packet)
            return Line(id: packet.id,
                        at: packet.timestamp,
                        from: packet.fromDisplay,
                        to: packet.toDisplay,
                        via: Self.via(packet),
                        summary: Self.summary(packet),
                        isOurs: marks.isOurs,
                        isForUs: marks.isForUs,
                        radio: packet.radioID)
        }
        merge()
    }

    /// A frame this station just put on the air.
    ///
    /// Kept even when the engine later logs our own frame coming back from a
    /// digipeater: the two are different events — one is "we keyed", the
    /// other is "somebody repeated us" — and an operator watching a beacon go
    /// out wants to see both.
    func record(_ line: Line) {
        sent.append(line)
        if sent.count > Self.bufferCapacity { sent.removeFirst(sent.count - Self.bufferCapacity) }
        merge()
    }

    /// The radio keyed, or gave up, on some of what it was holding.
    ///
    /// The modem transmits in order and reports counts, not identities, so
    /// the oldest pending lines resolve first — which is the order they were
    /// handed over in. Dropped frames are resolved before sent ones within a
    /// single report: the modem discards everything it is holding when it
    /// gives up, so a report carrying both means the drop came first and the
    /// send is from the queue that followed.
    func resolveTransmits(radio: RadioID, onAir: Int, dropped: Int) {
        guard onAir > 0 || dropped > 0 else { return }
        var remainingDropped = dropped
        var remainingOnAir = onAir
        for index in sent.indices where sent[index].radio == radio
            && sent[index].transmit == .pending {
            if remainingDropped > 0 {
                sent[index].transmit = .dropped
                remainingDropped -= 1
            } else if remainingOnAir > 0 {
                sent[index].transmit = .onAir
                remainingOnAir -= 1
            } else {
                break
            }
        }
        merge()
    }

    /// Everything the strip would show for one radio, newest first.
    func lines(for selected: RadioID?, visible: Set<RadioID>) -> [Line] {
        lines.filter { MapTrafficScope.shows(radio: $0.radio, selected: selected, visible: visible) }
            .prefix(Self.capacity)
            .map { $0 }
    }

    private func merge() {
        lines = (received + sent)
            .sorted { $0.at > $1.at }
            .prefix(Self.bufferCapacity)
            .map { $0 }
    }

    /// The digipeaters a frame actually came through — the ones marked used.
    /// An unused entry is a request, not a path taken, and printing it would
    /// claim a route the frame never travelled.
    static func via(_ packet: Packet) -> String {
        let used = packet.via.filter(\.repeated).map(\.display)
        return used.joined(separator: ",")
    }

    /// One line of what the frame said.
    static func summary(_ packet: Packet) -> String {
        let text = PayloadFormatter.asciiString(packet.info)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        // A frame with no printable payload still deserves a line — an RR or a
        // SABM is exactly the traffic an operator watching a connect wants to
        // see — so name the frame instead of printing an empty string.
        return text.isEmpty ? packet.frameType.rawValue.uppercased() : text
    }
}
