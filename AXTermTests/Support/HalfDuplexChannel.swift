//
//  HalfDuplexChannel.swift
//  AXTermTests
//
//  A deterministic simulated radio channel for connected-mode stress tests.
//
//  Every node is a KISS TNC and a half-duplex transmitter. The model follows
//  the live RF findings in Docs/LiveRFTest-2026-09-30.md:
//
//  - Airtime: each frame costs its bit-stuffed length plus FCS and a flag at
//    the node's bit rate, after a TX delay (preamble) at key-up, and a TX tail
//    after the last frame.
//  - Transmitter hang: some radios stay keyed after the tail (the IC-705
//    through Warbler held about 0.7 s). The hang is an unmodulated carrier, so
//    other TNCs' carrier detect does not see it, but the node cannot hear
//    while it lasts.
//  - Half duplex: a node hears nothing from key-up until its hang ends.
//  - Carrier sense: a TNC with frames waits while it hears a modulated signal
//    (preamble, frame or tail), then transmits with probability
//    persistence/256 per slot, like KISS p-persistence.
//  - Collisions: two signals that overlap at a receiver corrupt each other
//    there. There is no capture effect.
//  - Impairments per directed link: random loss, duplication, fades drawn
//    from an alternating exponential process, and fixed outages. A host to
//    TNC drop rate stands in for a lossy USB link.
//  - Digipeaters repeat frames whose next unused via address is theirs.
//
//  All randomness comes from seeded generators and every event is scheduled
//  on the AX25VirtualClock, so a seed always replays the same run.
//

import Foundation
@testable import AXTerm

// MARK: - Configuration

/// One node's TNC and transmitter.
struct SimRadioConfig {
    var bitRate: Double = 1200
    /// Preamble before the first frame of a transmission.
    var txDelay: TimeInterval = 0.3
    /// Flags after the last frame. Modulated, so carrier detect sees it.
    var txTail: TimeInterval = 0.03
    /// Unmodulated carrier after the tail. Not sensed by carrier detect; the
    /// node is deaf for its length.
    var hang: TimeInterval = 0
    /// Whether the hang carrier corrupts other signals at a receiver.
    var hangInterferes = true
    /// KISS persistence, 0 to 255.
    var persistence: Int = 63
    var slotTime: TimeInterval = 0.1
    /// How long a signal must have been on the air before carrier detect
    /// notices it.
    var dcdLatency: TimeInterval = 0
    /// Frames lost between the host and the TNC (lossy USB).
    var hostDropRate: Double = 0
    /// From the end of a frame on the air to the host seeing it.
    var decodeLatency: TimeInterval = 0.02
}

/// Fades on one directed link: clear and faded periods alternate, each with
/// an exponentially distributed length.
struct SimFadeModel {
    var meanClear: TimeInterval
    var meanFade: TimeInterval
}

/// What happens to frames from one node as heard at another.
struct SimLinkConfig {
    var audible = true
    var lossRate: Double = 0
    var duplicateRate: Double = 0
    var fade: SimFadeModel? = nil
    /// Fixed periods during which nothing gets through.
    var outages: [ClosedRange<TimeInterval>] = []
}

/// What became of one frame at one receiver.
enum SimReception: String, CaseIterable {
    case delivered
    /// The receiver was transmitting or in its hang.
    case deaf
    /// Another signal overlapped at the receiver.
    case collision
    case fade
    case outage
    case lost
    case poweredOff
}

/// One frame on the air.
struct SimAirFrame {
    let id: Int
    let bytes: Data
    let tag: Int
    let start: TimeInterval
    let end: TimeInterval
}

/// One key-up of one node, from key-down to the end of its hang.
final class SimTransmission {
    let node: Int
    let start: TimeInterval
    let preambleEnd: TimeInterval
    var frames: [SimAirFrame] = []
    var dataEnd: TimeInterval
    var tailEnd: TimeInterval
    var hangEnd: TimeInterval

    init(node: Int, start: TimeInterval, preambleEnd: TimeInterval) {
        self.node = node
        self.start = start
        self.preambleEnd = preambleEnd
        self.dataEnd = preambleEnd
        self.tailEnd = preambleEnd
        self.hangEnd = preambleEnd
    }
}

/// Counters for one run.
struct SimChannelStats {
    var framesHanded = 0
    var hostDrops = 0
    var transmissions = 0
    var framesOnAir = 0
    var busyDefers = 0
    var persistenceDefers = 0
    var duplicatesDelivered = 0
    /// Outcomes at the receiver each frame was meant for (the destination,
    /// or the digipeater that should repeat it).
    var intended: [SimReception: Int] = [:]
    /// Airtime keyed per node, preamble to tail.
    var airtime: [Int: TimeInterval] = [:]
    var maxQueueDepth: [Int: Int] = [:]

    var collisions: Int { intended[.collision] ?? 0 }
    var deafLosses: Int { intended[.deaf] ?? 0 }
}

// MARK: - Nodes

@MainActor
final class SimNode {
    let index: Int
    let name: String
    let call: AX25Address
    var radio: SimRadioConfig
    /// A digipeater repeats frames addressed through it; a station hands
    /// frames to its host.
    let isDigipeater: Bool
    var powered = true
    /// Called with every frame this node decodes.
    var deliver: ((Data) -> Void)?

    fileprivate(set) var queue: [(bytes: Data, tag: Int)] = []
    fileprivate(set) var current: SimTransmission?
    fileprivate var attemptScheduled = false

    init(index: Int, name: String, call: AX25Address, radio: SimRadioConfig, isDigipeater: Bool) {
        self.index = index
        self.name = name
        self.call = call
        self.radio = radio
        self.isDigipeater = isDigipeater
    }
}

// MARK: - Channel

@MainActor
final class HalfDuplexChannel {
    let clock: AX25VirtualClock
    let seed: UInt64
    private var rng: RFRng
    /// Clean flags a receiver must hear before a frame to synchronize on it.
    var syncBits: Double = 16
    var collisionsEnabled = true
    var defaultLink = SimLinkConfig()

    private(set) var nodes: [SimNode] = []
    private var links: [Int: SimLinkConfig] = [:]
    private var fades: [Int: FadeTimeline] = [:]
    private(set) var transmissions: [SimTransmission] = []
    private(set) var stats = SimChannelStats()
    private var nextFrameID = 0

    /// Every outcome at an intended receiver: frame tag, sender, receiver.
    var onReception: ((_ tag: Int, _ from: Int, _ to: Int, _ outcome: SimReception) -> Void)?
    /// A bounded log of channel events for failure reports.
    private(set) var trace: [String] = []
    var traceLimit = 400

    init(clock: AX25VirtualClock, seed: UInt64) {
        self.clock = clock
        self.seed = seed
        self.rng = RFRng(seed: seed ^ 0xC4A7_7E1D_0000_0001)
    }

    // MARK: Building

    @discardableResult
    func addNode(name: String, call: AX25Address, radio: SimRadioConfig = SimRadioConfig(),
                 isDigipeater: Bool = false) -> SimNode {
        let node = SimNode(index: nodes.count, name: name, call: call, radio: radio,
                           isDigipeater: isDigipeater)
        nodes.append(node)
        if isDigipeater {
            node.deliver = { [weak self, weak node] bytes in
                guard let self, let node else { return }
                self.digipeat(bytes, by: node)
            }
        }
        return node
    }

    func setLink(from: Int, to: Int, _ config: SimLinkConfig) {
        links[from * 64 + to] = config
    }

    func setLinks(between a: Int, and b: Int, _ config: SimLinkConfig) {
        setLink(from: a, to: b, config)
        setLink(from: b, to: a, config)
    }

    func link(from: Int, to: Int) -> SimLinkConfig {
        links[from * 64 + to] ?? defaultLink
    }

    // MARK: Airtime

    /// Bits on the air for one frame: the bytes with HDLC bit stuffing
    /// counted exactly, then 16 FCS bits and the closing flag.
    nonisolated static func frameBits(_ bytes: Data) -> Int {
        var bits = 0
        var ones = 0
        for byte in bytes {
            for i in 0..<8 {
                bits += 1
                if (byte >> i) & 1 == 1 {
                    ones += 1
                    if ones == 5 { bits += 1; ones = 0 }
                } else {
                    ones = 0
                }
            }
        }
        return bits + 16 + 8
    }

    func airtime(_ bytes: Data, at bitRate: Double) -> TimeInterval {
        Double(Self.frameBits(bytes)) / bitRate
    }

    // MARK: Host interface

    /// The host hands a frame to its TNC.
    func send(from index: Int, bytes: Data, tag: Int) {
        let node = nodes[index]
        stats.framesHanded += 1
        guard node.powered else { return }
        if node.radio.hostDropRate > 0, rng.chance(node.radio.hostDropRate) {
            stats.hostDrops += 1
            note("\(node.name) USB drop tag=\(tag)")
            return
        }
        let now = clock.currentTime
        // A TNC still sending frames carries on with any that arrive before
        // its last frame ends, in the same transmission.
        if let tx = node.current, now < tx.dataEnd {
            appendFrame(bytes, tag: tag, to: tx, node: node)
            return
        }
        node.queue.append((bytes, tag))
        stats.maxQueueDepth[index] = max(stats.maxQueueDepth[index] ?? 0, node.queue.count)
        scheduleAttempt(node, at: max(now, node.current?.tailEnd ?? now))
    }

    /// Frames waiting in a node's TNC.
    func queueDepth(of index: Int) -> Int { nodes[index].queue.count }

    /// Whether a node is keyed with frames or flags going out.
    func isTransmitting(_ index: Int) -> Bool {
        guard let tx = nodes[index].current else { return false }
        return clock.currentTime < tx.tailEnd
    }

    /// Whether a node still has frames to send, queued or on the air.
    func hasFramesPending(_ index: Int) -> Bool {
        let node = nodes[index]
        if !node.queue.isEmpty { return true }
        if let tx = node.current, clock.currentTime < tx.dataEnd { return true }
        return false
    }

    /// Frames a node has not finished sending: queued in its TNC, or on the
    /// air and not yet ended.
    func unsentFrames(of index: Int) -> [Data] {
        let node = nodes[index]
        var frames = node.queue.map(\.bytes)
        if let tx = node.current {
            let now = clock.currentTime
            frames.append(contentsOf: tx.frames.filter { $0.end > now }.map(\.bytes))
        }
        return frames
    }

    /// Turns a node off or on. Off drops its queue; it neither sends nor hears.
    func setPowered(_ index: Int, _ on: Bool) {
        let node = nodes[index]
        node.powered = on
        if !on { node.queue.removeAll() }
        note("\(node.name) power \(on ? "on" : "off")")
    }

    // MARK: Channel access

    private func scheduleAttempt(_ node: SimNode, at time: TimeInterval) {
        guard !node.attemptScheduled else { return }
        node.attemptScheduled = true
        let delay = max(0, time - clock.currentTime)
        _ = clock.schedule(delay: delay) { [weak self, weak node] in
            guard let self, let node else { return }
            node.attemptScheduled = false
            self.attempt(node)
        }
    }

    private func attempt(_ node: SimNode) {
        guard node.powered, !node.queue.isEmpty else { return }
        let now = clock.currentTime
        if let tx = node.current, now < tx.tailEnd {
            scheduleAttempt(node, at: tx.tailEnd)
            return
        }
        if let busyUntil = sensedBusy(by: node) {
            stats.busyDefers += 1
            scheduleAttempt(node, at: busyUntil)
            return
        }
        if node.radio.persistence < 255, Int(rng.next() & 0xFF) > node.radio.persistence {
            stats.persistenceDefers += 1
            scheduleAttempt(node, at: now + node.radio.slotTime)
            return
        }
        keyUp(node)
    }

    /// When the channel as this node hears it goes quiet, or nil if it is
    /// quiet now. A node in its own hang hears nothing, so it senses nothing.
    private func sensedBusy(by node: SimNode) -> TimeInterval? {
        let now = clock.currentTime
        if isDeaf(node.index, at: now) { return nil }
        var until: TimeInterval?
        for tx in transmissions.reversed() {
            if tx.tailEnd < now - 120 { break }
            guard tx.node != node.index, link(from: tx.node, to: node.index).audible,
                  nodes[tx.node].powered else { continue }
            // Strictly before: two TNCs deciding in the same instant
            // cannot hear each other's key-up yet.
            if tx.start + node.radio.dcdLatency < now, now < tx.tailEnd {
                until = max(until ?? 0, tx.tailEnd)
            }
        }
        return until
    }

    private func keyUp(_ node: SimNode) {
        let now = clock.currentTime
        let tx = SimTransmission(node: node.index, start: now, preambleEnd: now + node.radio.txDelay)
        node.current = tx
        transmissions.append(tx)
        stats.transmissions += 1
        stats.airtime[node.index, default: 0] += node.radio.txDelay
        let frames = node.queue
        node.queue.removeAll()
        note("\(node.name) key-up with \(frames.count) frame(s)")
        for frame in frames {
            appendFrame(frame.bytes, tag: frame.tag, to: tx, node: node)
        }
        pruneHistory()
    }

    private func appendFrame(_ bytes: Data, tag: Int, to tx: SimTransmission, node: SimNode) {
        let start = tx.dataEnd
        let end = start + airtime(bytes, at: node.radio.bitRate)
        nextFrameID += 1
        let frame = SimAirFrame(id: nextFrameID, bytes: bytes, tag: tag, start: start, end: end)
        tx.frames.append(frame)
        let oldTail = tx.tailEnd
        tx.dataEnd = end
        tx.tailEnd = end + node.radio.txTail
        tx.hangEnd = tx.tailEnd + node.radio.hang
        stats.framesOnAir += 1
        stats.airtime[node.index, default: 0] += tx.tailEnd - oldTail
        _ = clock.schedule(delay: end - clock.currentTime) { [weak self] in
            self?.frameEnded(frame, from: node.index)
        }
        let txRef = tx
        _ = clock.schedule(delay: tx.tailEnd - clock.currentTime) { [weak self, weak node] in
            guard let self, let node, txRef.tailEnd <= self.clock.currentTime else { return }
            // Frames that came in during the tail wait for a fresh key-up.
            if !node.queue.isEmpty { self.scheduleAttempt(node, at: self.clock.currentTime) }
        }
    }

    private func pruneHistory() {
        let horizon = clock.currentTime - 300
        if let first = transmissions.firstIndex(where: { $0.hangEnd >= horizon }), first > 0 {
            transmissions.removeFirst(first)
        }
    }

    // MARK: Reception

    private func isDeaf(_ index: Int, at time: TimeInterval) -> Bool {
        for tx in transmissions.reversed() where tx.node == index {
            if tx.start <= time, time < tx.hangEnd { return true }
            if tx.hangEnd < time - 60 { break }
        }
        return false
    }

    private func deafOverlaps(_ index: Int, _ lo: TimeInterval, _ hi: TimeInterval) -> Bool {
        transmissions.contains { $0.node == index && $0.start < hi && $0.hangEnd > lo }
    }

    private func interferenceOverlaps(at receiver: Int, excluding sender: Int,
                                      _ lo: TimeInterval, _ hi: TimeInterval) -> Bool {
        transmissions.contains { tx in
            guard tx.node != sender, tx.node != receiver,
                  link(from: tx.node, to: receiver).audible else { return false }
            let signalEnd = nodes[tx.node].radio.hangInterferes ? tx.hangEnd : tx.tailEnd
            return tx.start < hi && signalEnd > lo
        }
    }

    private func frameEnded(_ frame: SimAirFrame, from sender: Int) {
        let intended = intendedReceiver(of: frame.bytes)
        let syncTime = syncBits / nodes[sender].radio.bitRate
        for receiver in nodes where receiver.index != sender {
            let link = link(from: sender, to: receiver.index)
            guard link.audible else { continue }
            let outcome: SimReception
            if !receiver.powered || !nodes[sender].powered {
                outcome = .poweredOff
            } else if deafOverlaps(receiver.index, frame.start - syncTime, frame.end) {
                outcome = .deaf
            } else if collisionsEnabled,
                      interferenceOverlaps(at: receiver.index, excluding: sender,
                                           frame.start - syncTime, frame.end) {
                outcome = .collision
            } else if link.outages.contains(where: { $0.lowerBound < frame.end && $0.upperBound > frame.start }) {
                outcome = .outage
            } else if let fade = link.fade,
                      fadeTimeline(from: sender, to: receiver.index, model: fade)
                        .overlaps(frame.start, frame.end) {
                outcome = .fade
            } else if link.lossRate > 0, rng.chance(link.lossRate) {
                outcome = .lost
            } else {
                outcome = .delivered
            }
            if receiver.index == intended {
                stats.intended[outcome, default: 0] += 1
                onReception?(frame.tag, sender, receiver.index, outcome)
                if outcome != .delivered {
                    note("\(nodes[sender].name)->\(receiver.name) tag=\(frame.tag) \(outcome.rawValue)")
                }
            }
            guard outcome == .delivered else { continue }
            let bytes = frame.bytes
            let latency = receiver.radio.decodeLatency
            _ = clock.schedule(delay: latency) { [weak receiver] in
                guard let receiver, receiver.powered else { return }
                receiver.deliver?(bytes)
            }
            if link.duplicateRate > 0, rng.chance(link.duplicateRate) {
                stats.duplicatesDelivered += 1
                let extra = rng.uniform(0.05, 0.3)
                _ = clock.schedule(delay: latency + extra) { [weak receiver] in
                    guard let receiver, receiver.powered else { return }
                    receiver.deliver?(bytes)
                }
            }
        }
    }

    /// The node a frame is meant for: the digipeater that should repeat it
    /// next, or else the station it is addressed to.
    private func intendedReceiver(of bytes: Data) -> Int? {
        guard let frame = AX25.decodeFrame(ax25: bytes) else { return nil }
        if let next = frame.via.first(where: { !$0.repeated }) {
            return nodes.first { $0.isDigipeater && Self.sameStation($0.call, next) }?.index
        }
        guard let to = frame.to else { return nil }
        return nodes.first { !$0.isDigipeater && Self.sameStation($0.call, to) }?.index
    }

    nonisolated static func sameStation(_ a: AX25Address, _ b: AX25Address) -> Bool {
        a.call == b.call && a.ssid == b.ssid
    }

    // MARK: Digipeating

    private func digipeat(_ bytes: Data, by node: SimNode) {
        guard let frame = AX25.decodeFrame(ax25: bytes),
              let hop = frame.via.firstIndex(where: { !$0.repeated }),
              Self.sameStation(frame.via[hop], node.call) else { return }
        var repeated = bytes
        let ssidByte = repeated.startIndex + 14 + 7 * hop + 6
        repeated[ssidByte] |= 0x80
        send(from: node.index, bytes: repeated, tag: -1)
    }

    // MARK: Fades

    private func fadeTimeline(from: Int, to: Int, model: SimFadeModel) -> FadeTimeline {
        let key = from * 64 + to
        if let existing = fades[key] { return existing }
        let timeline = FadeTimeline(model: model,
                                    seed: seed ^ (UInt64(key) &* 0x9E37_79B9_7F4A_7C15) ^ 0xFADE)
        fades[key] = timeline
        return timeline
    }

    // MARK: Trace

    func note(_ message: String) {
        trace.append(String(format: "%9.3f ", clock.currentTime) + message)
        if trace.count > traceLimit { trace.removeFirst(trace.count - traceLimit) }
    }
}

/// Alternating clear and faded periods on one link, generated as far ahead
/// as anyone asks, from the link's own generator so the timeline does not
/// depend on how many other random draws the run made.
@MainActor
final class FadeTimeline {
    private let model: SimFadeModel
    private var rng: RFRng
    /// Faded intervals, in order.
    private(set) var fadesSoFar: [ClosedRange<TimeInterval>] = []
    private var generatedUntil: TimeInterval = 0

    init(model: SimFadeModel, seed: UInt64) {
        self.model = model
        self.rng = RFRng(seed: seed)
    }

    private func exponential(mean: TimeInterval) -> TimeInterval {
        -mean * log(max(1e-12, 1 - rng.nextDouble()))
    }

    func overlaps(_ lo: TimeInterval, _ hi: TimeInterval) -> Bool {
        while generatedUntil < hi {
            let clearEnd = generatedUntil + exponential(mean: model.meanClear)
            let fadeEnd = clearEnd + exponential(mean: model.meanFade)
            fadesSoFar.append(clearEnd...fadeEnd)
            generatedUntil = fadeEnd
        }
        return fadesSoFar.contains { $0.lowerBound < hi && $0.upperBound > lo }
    }
}
