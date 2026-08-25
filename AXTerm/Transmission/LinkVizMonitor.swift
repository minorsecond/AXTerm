import Foundation
import Combine

// MARK: - Events emitted by AX25SessionManager

/// A single observable moment on a connected AX.25 link, emitted by
/// `AX25SessionManager` for live visualization. Deliberately tiny — the
/// session manager is on the hot path.
nonisolated enum LinkVizEvent: Sendable {
    /// Window/timer snapshot taken whenever the session state is dumped
    /// (inbound I, inbound RR, T1 timeout, …). `context` matches the debug
    /// trace contexts ("inbound-I", "inbound-RR", "inbound-RR-poll",
    /// "T1-timeout", "inbound-REJ", "inbound-RNR").
    case snapshot(LinkWindowSnapshot)
    /// Raw inbound I-frame observed for this peer (before dup/order checks).
    case inboundIFrame(peer: String, ns: Int, bytes: Int)
    /// Payload bytes delivered in-order to the application.
    case delivered(peer: String, bytes: Int)
    /// We asked the peer to retransmit from `nr` (a gap was detected).
    case rejSent(peer: String, nr: Int)
    /// We retransmitted `count` of our own I-frames.
    case retransmit(peer: String, count: Int)
}

nonisolated struct LinkWindowSnapshot: Sendable, Equatable {
    let peer: String
    let context: String
    let vs: Int
    let va: Int
    let vr: Int
    let outstanding: Int
    let windowSize: Int
    let retryCount: Int
    let sendBufferSeq: [Int]
    let rto: Double
    let srtt: Double?
    let rttvar: Double
    let date: Date

    /// Session-lifetime frame counters, carried here so the UI can show
    /// both directions of the link. Forward health comes from our own
    /// retransmissions; reverse health from the REJs we had to send.
    /// Defaulted so older call sites and tests keep compiling.
    var framesSent: Int = 0
    var framesReceived: Int = 0
    var retransmissions: Int = 0
    var rejSent: Int = 0

    /// Forward delivery probability: our I-frames that landed first try.
    var df: Double? {
        let transmissions = framesSent + retransmissions
        guard transmissions > 0 else { return nil }
        return 1.0 - Double(retransmissions) / Double(transmissions)
    }

    /// Reverse delivery probability: the peer's I-frames that reached us
    /// without a gap. Each REJ we sent marks one gap.
    var dr: Double? {
        let observations = framesReceived + rejSent
        guard observations > 0 else { return nil }
        return 1.0 - Double(rejSent) / Double(observations)
    }

    /// CLAUDE.md §8: 1 / (df · dr), clamped to [1, 20]. Nil until at least
    /// one direction has evidence.
    var etx: Double? {
        guard df != nil || dr != nil else { return nil }
        let forward = df ?? dr ?? 1
        let reverse = dr ?? forward
        return min(20, max(1, 1 / (max(forward, 0.05) * max(reverse, 0.05))))
    }
}

// MARK: - Per-link aggregate

/// Everything the visualizations need about one peer link, aggregated from
/// the raw event stream with bounded memory.
@MainActor
final class LinkSessionViz: ObservableObject, Identifiable {
    nonisolated let peer: String
    nonisolated var id: String { peer }

    struct RTTSample: Identifiable {
        let date: Date
        let srtt: Double
        let rttvar: Double
        let rto: Double
        var id: Date { date }
    }

    struct WindowSample: Identifiable {
        let date: Date
        let outstanding: Int
        let windowSize: Int
        /// "rej", "t1" or nil — marks loss events on the sawtooth.
        let lossEvent: String?
        var id: Date { date }
    }

    struct Delivery: Identifiable {
        let date: Date
        let bytes: Int
        let id = UUID()
    }

    struct ThroughputBucket: Identifiable {
        let date: Date            // second-aligned
        var rawBytes: Int         // all inbound I payload incl. retransmitted copies
        var deliveredBytes: Int   // in-order goodput
        var id: Date { date }
    }

    @Published private(set) var snapshot: LinkWindowSnapshot?
    @Published private(set) var rttHistory: [RTTSample] = []
    @Published private(set) var windowHistory: [WindowSample] = []
    @Published private(set) var deliveries: [Delivery] = []
    @Published private(set) var throughput: [ThroughputBucket] = []

    @Published private(set) var totalRawBytes = 0
    @Published private(set) var totalDeliveredBytes = 0
    @Published private(set) var rejCount = 0
    @Published private(set) var t1Count = 0
    @Published private(set) var retransmitCount = 0
    @Published private(set) var lastActivity = Date.distantPast

    private static let rttCap = 400
    private static let windowCap = 800
    private static let deliveryCap = 900
    private static let throughputCap = 900  // 15 min of 1 s buckets

    init(peer: String) {
        self.peer = peer
    }

    /// nonisolated: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the deinit
    /// would otherwise be isolated, and a synchronous release (e.g. tearing
    /// down a SessionCoordinator in tests) aborts in the runtime's task-local
    /// teardown (swift_task_deinitOnExecutorImpl → StopLookupScope,
    /// malloc double-free). All stored state is Sendable value types.
    nonisolated deinit {}

    /// Retransmit overhead of the receive direction: 1 − goodput/raw.
    var receiveOverheadFraction: Double {
        guard totalRawBytes > 0 else { return 0 }
        return 1 - Double(totalDeliveredBytes) / Double(totalRawBytes)
    }

    func apply(_ event: LinkVizEvent, now: Date = Date()) {
        lastActivity = now
        switch event {
        case .snapshot(let snap):
            snapshot = snap
            var loss: String?
            if snap.context == "T1-timeout" {
                t1Count += 1
                loss = "t1"
            }
            appendWindow(WindowSample(
                date: snap.date, outstanding: snap.outstanding,
                windowSize: snap.windowSize, lossEvent: loss))
            if let srtt = snap.srtt {
                if rttHistory.last.map({ abs($0.srtt - srtt) > 0.0005 || abs($0.rto - snap.rto) > 0.0005 }) ?? true {
                    rttHistory.append(RTTSample(date: snap.date, srtt: srtt, rttvar: snap.rttvar, rto: snap.rto))
                    if rttHistory.count > Self.rttCap { rttHistory.removeFirst(rttHistory.count - Self.rttCap) }
                }
            }
        case .inboundIFrame(_, _, let bytes):
            totalRawBytes += bytes
            bump(raw: bytes, delivered: 0, now: now)
        case .delivered(_, let bytes):
            totalDeliveredBytes += bytes
            bump(raw: 0, delivered: bytes, now: now)
            deliveries.append(Delivery(date: now, bytes: bytes))
            if deliveries.count > Self.deliveryCap { deliveries.removeFirst(deliveries.count - Self.deliveryCap) }
        case .rejSent:
            rejCount += 1
            if let snap = snapshot {
                appendWindow(WindowSample(
                    date: now, outstanding: snap.outstanding,
                    windowSize: snap.windowSize, lossEvent: "rej"))
            }
        case .retransmit(_, let count):
            retransmitCount += count
        }
    }

    /// Resets per-transfer counters (called when a new protocol exchange starts
    /// on this link) while keeping the RTT/window history for continuity.
    func resetTransferCounters() {
        totalRawBytes = 0
        totalDeliveredBytes = 0
        rejCount = 0
        t1Count = 0
        retransmitCount = 0
        deliveries.removeAll()
        throughput.removeAll()
    }

    private func appendWindow(_ sample: WindowSample) {
        windowHistory.append(sample)
        if windowHistory.count > Self.windowCap {
            windowHistory.removeFirst(windowHistory.count - Self.windowCap)
        }
    }

    private func bump(raw: Int, delivered: Int, now: Date) {
        let second = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        if let last = throughput.indices.last, throughput[last].date == second {
            throughput[last].rawBytes += raw
            throughput[last].deliveredBytes += delivered
        } else {
            throughput.append(ThroughputBucket(date: second, rawBytes: raw, deliveredBytes: delivered))
            if throughput.count > Self.throughputCap {
                throughput.removeFirst(throughput.count - Self.throughputCap)
            }
        }
    }
}

/// Routes `LinkVizEvent`s from the session manager into per-peer aggregates.
@MainActor
final class LinkVizMonitor: ObservableObject {
    @Published private(set) var sessions: [String: LinkSessionViz] = [:]

    nonisolated init() {}
    /// See LinkSessionViz.deinit — isolated deinit aborts on synchronous release.
    nonisolated deinit {}

    func ingest(_ event: LinkVizEvent) {
        let peer: String
        switch event {
        case .snapshot(let s): peer = s.peer
        case .inboundIFrame(let p, _, _), .delivered(let p, _),
             .rejSent(let p, _), .retransmit(let p, _):
            peer = p
        }
        viz(for: peer).apply(event)
    }

    func viz(for peer: String) -> LinkSessionViz {
        let key = peer.uppercased()
        if let existing = sessions[key] { return existing }
        let created = LinkSessionViz(peer: key)
        sessions[key] = created
        return created
    }

    /// The most recently active link — what the popover shows when no
    /// specific session is selected.
    var mostRecentlyActive: LinkSessionViz? {
        sessions.values.max { $0.lastActivity < $1.lastActivity }
    }
}

// MARK: - Channel airtime

/// Records who is using the shared channel and for how long. Airtime is
/// estimated from frame length at the configured baud rate (HDLC adds
/// flags/CRC/bit-stuffing; the +6 byte overhead and the 1.05 stuffing factor
/// keep the estimate honest without a bit-exact model).
@MainActor
final class ChannelActivityMonitor: ObservableObject {
    static let shared = ChannelActivityMonitor()

    struct Sample: Identifiable {
        let date: Date
        let callsign: String
        let airtimeSeconds: Double
        let isTransmit: Bool
        let id = UUID()
    }

    @Published private(set) var samples: [Sample] = []
    /// Sliding window the lanes view covers.
    nonisolated static let window: TimeInterval = 10 * 60
    private static let cap = 4000

    var baudRate = 1200.0

    nonisolated init() {}
    /// See LinkSessionViz.deinit — isolated deinit aborts on synchronous release.
    nonisolated deinit {}

    func record(callsign: String, frameBytes: Int, isTransmit: Bool, date: Date = Date()) {
        let bits = Double(frameBytes + 6) * 8.0 * 1.05
        let sample = Sample(
            date: date,
            callsign: callsign.uppercased(),
            airtimeSeconds: bits / baudRate,
            isTransmit: isTransmit)
        samples.append(sample)
        trim(now: date)
    }

    private func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.window)
        if let firstKept = samples.firstIndex(where: { $0.date >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
        if samples.count > Self.cap { samples.removeFirst(samples.count - Self.cap) }
    }

    /// Callsigns ordered by airtime within the window (busiest first).
    var lanes: [(callsign: String, airtime: Double)] {
        var totals: [String: Double] = [:]
        for s in samples { totals[s.callsign, default: 0] += s.airtimeSeconds }
        return totals.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    /// Fraction of the window the channel was occupied (all stations).
    func utilization(now: Date = Date()) -> Double {
        guard let first = samples.first else { return 0 }
        let span = min(Self.window, max(now.timeIntervalSince(first.date), 1))
        let busy = samples.reduce(0) { $0 + $1.airtimeSeconds }
        return min(1, busy / span)
    }
}

// MARK: - Graph pulses

/// Broadcasts "a frame just traversed src→dst" so the network graph can
/// briefly glow the corresponding edge. A callback bus (not Combine) to keep
/// the packet hot path allocation-free.
@MainActor
final class GraphPulseBus {
    static let shared = GraphPulseBus()
    /// Set by the graph renderer while it is on screen.
    var onPulse: ((_ from: String, _ to: String) -> Void)?

    nonisolated init() {}

    func pulse(from: String, to: String) {
        onPulse?(from.uppercased(), to.uppercased())
    }
}
