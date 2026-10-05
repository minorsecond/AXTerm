//
//  ConnectedModeStress.swift
//  AXTermTests
//
//  Scenarios and a runner for stressing AX.25 connected mode end to end on
//  the HalfDuplexChannel. One run is two stations (and optionally a
//  digipeater), a seeded channel, some traffic and some events, and it
//  reports what happened and every invariant that broke.
//
//  Invariants checked on every run:
//  - what each side's application received is always a prefix of what the
//    other side's application sent (nothing lost from the middle, nothing
//    twice, nothing out of order), and all of it when the link survives;
//  - the run makes progress or the link fails, within a bound;
//  - a failed link is reported by both sides within a bound;
//  - both sides end in consistent states;
//  - no station piles frames into its TNC without bound.
//  Sequence-state invariants are asserted by the manager itself after every
//  send and receive (`checkInvariants`), which traps in a debug build.
//

import Foundation
import XCTest
@testable import AXTerm

/// Which link behavior a run uses.
enum StressMode: String, CaseIterable {
    /// Production defaults toward a station not known to hold its acks
    /// (no AXDP): T1 per AX.25 2.2 (spec 7.3), in-session growth off.
    case defaults
    /// SessionCoordinator.inSessionLinkGrowth on.
    case growth
}

enum StressTraffic {
    /// Bulk data in each direction, written as the session's queue drains.
    case bulk(aToB: Int, bToA: Int)
    /// Lines of text at random intervals.
    case chat(linesEach: Int, meanGap: TimeInterval, bothWays: Bool)
}

enum StressEvent {
    /// A station asks to disconnect.
    case disconnect(at: TimeInterval, station: Int)
    /// A station crashes and restarts with no sessions; optionally it then
    /// connects again.
    case restart(at: TimeInterval, station: Int, reconnect: Bool)
    /// A radio is switched off or on.
    case power(at: TimeInterval, station: Int, on: Bool)
}

struct StressScenario: CustomStringConvertible {
    var name: String
    var seed: UInt64
    var mode: StressMode = .defaults
    var bitRate: Double = 1200
    var txDelay: (a: TimeInterval, b: TimeInterval) = (0.3, 0.3)
    var hang: (a: TimeInterval, b: TimeInterval) = (0, 0)
    var txTail: TimeInterval = 0.03
    var persistence = 63
    var slotTime: TimeInterval = 0.1
    var loss: Double = 0
    var duplicate: Double = 0
    var fade: SimFadeModel? = nil
    var outages: [ClosedRange<TimeInterval>] = []
    /// From this time on, nothing station `from` sends gets through to the
    /// next hop; the other direction stays clear.
    var oneWayOutage: (from: Int, start: TimeInterval)? = nil
    var hostDrop: Double = 0
    var viaDigi = false
    /// Nil keeps the adaptive defaults (K=2, paclen 128).
    var window: Int? = nil
    var paclen: Int? = nil
    var frack: Double = 4.0
    var traffic: StressTraffic = .bulk(aToB: 4096, bToA: 0)
    var events: [StressEvent] = []
    /// B also calls A this long after A called B (0 is the same instant).
    var connectOffset: TimeInterval? = nil
    /// Disconnect gracefully once everything is delivered.
    var disconnectAtEnd = true
    var timeLimit: TimeInterval = 4 * 3600

    var description: String {
        var parts = ["\(name) seed=\(seed) mode=\(mode.rawValue) \(Int(bitRate))bps"]
        parts.append("K=\(window.map(String.init) ?? "auto") P=\(paclen.map(String.init) ?? "auto") FRACK=\(frack)")
        parts.append("txd=\(txDelay.a)/\(txDelay.b) hang=\(hang.a)/\(hang.b) p=\(persistence)")
        if connectOffset != nil { parts.append("both call, B after \(String(format: "%.2f", connectOffset ?? 0)) s") }
        if loss > 0 { parts.append("loss=\(loss)") }
        if duplicate > 0 { parts.append("dup=\(duplicate)") }
        if let fade { parts.append("fade=\(fade.meanClear)/\(fade.meanFade)") }
        if hostDrop > 0 { parts.append("usb=\(hostDrop)") }
        if viaDigi { parts.append("via digi") }
        return parts.joined(separator: " ")
    }
}

struct StressResult {
    var scenario: String
    var completed = false
    var linkFailed = false
    var violations: [String] = []
    /// Stream breaks caused by the receive-gap flush (see checkStreams).
    var gapFlushLosses: [String] = []
    var elapsed: TimeInterval = 0
    var dataTime: TimeInterval = 0
    var bytesDelivered = 0
    var newIFrames = 0
    var retransmittedIFrames = 0
    var collisions = 0
    var deafLosses = 0
    var transmissions = 0
    var timers = SimTimerMetrics()
    var midBurstT2Lost = 0
    var t2AcksLost = 0
    var maxQueueDepth = 0
    var fingerprint = ""
    var trace: [String] = []
    /// UAs either station received while already connected.
    var unexpectedUAs = 0
    var firstUnexpectedUA: TimeInterval?
    /// Times either station told its application the link was reset (the
    /// old link ended and a new one began in the same instant), which the
    /// AX.25 2.2 SDL does only on the side that lost frames.
    var resetIndications: [TimeInterval] = []
    /// How long after the first side's link went down the second side's
    /// did, when both did.
    var failureLag: TimeInterval?
    var firstViolationAt: TimeInterval?

    var throughput: Double { dataTime > 0 ? Double(bytesDelivered * 8) / dataTime : 0 }
    var retransmissionRatio: Double {
        newIFrames > 0 ? Double(retransmittedIFrames) / Double(newIFrames) : 0
    }

    var summary: String {
        String(format: "%@ | %@%@ %.0f bps, retx %.2f, coll %d, deaf %d, earlyT1 %d (own %d, T2 %d, ack %d), T1 %d, T2 %d mid %d (lost %d), tnc max %d",
               scenario, completed ? "ok" : (linkFailed ? "FAILED-LINK" : "INCOMPLETE"),
               gapFlushLosses.isEmpty ? "" : " GAP-FLUSH-LOSS",
               throughput, retransmissionRatio, collisions, deafLosses,
               timers.earlyT1, timers.earlyT1OwnBurst, timers.earlyT1PeerT2, timers.earlyT1AckInFlight,
               timers.t1Batches, timers.t2Acks, timers.midBurstT2, midBurstT2Lost, maxQueueDepth)
    }
}

@MainActor
final class StressRunner {
    let scenario: StressScenario
    let net: StressNet
    let a: SimStation
    let b: SimStation
    let path: DigiPath
    private var brains: [SessionCoordinator] = []
    private var trafficRng: RFRng
    private var result: StressResult
    private var pendingBulk: [Int] = [0, 0]
    private var chatLinesLeft: [Int] = [0, 0]
    private var nextChatAt: [TimeInterval] = [0, 0]
    private var firstWriteAt: TimeInterval?
    private var lastDeliveryAt: TimeInterval = 0
    private var lastDelivered = 0
    private var lastProgressAt: TimeInterval = 0
    private var lastStateLogCount = 0
    private var dataDone = false
    private var disconnectRequestedAt: TimeInterval?
    private var failureSeenAt: TimeInterval?
    private var checkedPrefix: [Int] = [0, 0]
    private var checkedEpochs: [[Int]] = [[0, 0], [0, 0]]
    /// A direction whose stream already broke (gap flush or a reported
    /// violation): no longer compared, and done once quiescent.
    private var gapFlushed = [false, false]
    private var silentResetsSeen: [String: Int] = [:]
    private var reportedViolations: Set<String> = []

    static let addressA = AX25Address(call: "K0AAA", ssid: 1)
    static let addressB = AX25Address(call: "K0BBB", ssid: 2)
    static let addressDigi = AX25Address(call: "DIGI", ssid: 1)

    init(_ scenario: StressScenario) {
        self.scenario = scenario
        self.result = StressResult(scenario: scenario.description)
        self.trafficRng = RFRng(seed: scenario.seed ^ 0x7AFF_1C00)
        net = StressNet(seed: scenario.seed)
        let channel = net.channel

        func radio(txDelay: TimeInterval, hang: TimeInterval) -> SimRadioConfig {
            var r = SimRadioConfig()
            r.bitRate = scenario.bitRate
            r.txDelay = txDelay
            r.txTail = scenario.txTail
            r.hang = hang
            r.persistence = scenario.persistence
            r.slotTime = scenario.slotTime
            r.hostDropRate = scenario.hostDrop
            return r
        }
        let nodeA = channel.addNode(name: "A", call: Self.addressA,
                                    radio: radio(txDelay: scenario.txDelay.a, hang: scenario.hang.a))
        let nodeB = channel.addNode(name: "B", call: Self.addressB,
                                    radio: radio(txDelay: scenario.txDelay.b, hang: scenario.hang.b))
        let impaired = SimLinkConfig(audible: true, lossRate: scenario.loss,
                                     duplicateRate: scenario.duplicate, fade: scenario.fade,
                                     outages: scenario.outages)
        if scenario.viaDigi {
            var digiRadio = radio(txDelay: 0.3, hang: 0)
            digiRadio.hostDropRate = 0
            let digi = channel.addNode(name: "D", call: Self.addressDigi, radio: digiRadio, isDigipeater: true)
            channel.setLinks(between: nodeA.index, and: nodeB.index, SimLinkConfig(audible: false))
            channel.setLinks(between: nodeA.index, and: digi.index, impaired)
            channel.setLinks(between: nodeB.index, and: digi.index, impaired)
            path = DigiPath([Self.addressDigi])
        } else {
            channel.setLinks(between: nodeA.index, and: nodeB.index, impaired)
            path = DigiPath()
        }

        if let cut = scenario.oneWayOutage {
            let from = cut.from == 0 ? nodeA.index : nodeB.index
            let to = scenario.viaDigi ? 2 : (cut.from == 0 ? nodeB.index : nodeA.index)
            var dead = channel.link(from: from, to: to)
            dead.outages.append(cut.start...1e9)
            channel.setLink(from: from, to: to, dead)
        }

        func source(_ call: AX25Address) -> SimConfigSource {
            let brain = SessionCoordinator()
            brain.localCallsign = call.display
            brain.adaptiveTransmissionEnabled = true
            // "defaults" is growth off: what a session runs toward a station
            // not known to hold its acks, or before AXDP is confirmed.
            brain.inSessionLinkGrowth = scenario.mode == .growth
            // Both simulated stations are AXTerm, whose receiver holds its
            // delayed ack until a burst pauses (a148309).
            brain.peerHoldsAcksThroughBursts = { _ in true }
            if let k = scenario.window {
                brain.globalAdaptiveSettings.windowSize.mode = .manual
                brain.globalAdaptiveSettings.windowSize.manualValue = k
            }
            if let p = scenario.paclen {
                brain.globalAdaptiveSettings.paclen.mode = .manual
                brain.globalAdaptiveSettings.paclen.manualValue = p
            }
            return .coordinator(brain, frack: scenario.frack)
        }
        let srcA = source(Self.addressA)
        let srcB = source(Self.addressB)
        if case .coordinator(let brain, _) = srcA { brains.append(brain) }
        if case .coordinator(let brain, _) = srcB { brains.append(brain) }
        a = SimStation(net: net, name: "A", address: Self.addressA, node: nodeA.index, config: srcA)
        b = SimStation(net: net, name: "B", address: Self.addressB, node: nodeB.index, config: srcB)
        net.add(a)
        net.add(b)

        switch scenario.traffic {
        case .bulk(let ab, let ba):
            pendingBulk = [ab, ba]
        case .chat(let lines, _, let both):
            chatLinesLeft = [lines, both ? lines : 0]
        }
    }

    private var stations: [SimStation] { [a, b] }
    private func peer(of i: Int) -> SimStation { i == 0 ? b : a }

    private func violation(_ message: String) {
        guard !reportedViolations.contains(message) else { return }
        reportedViolations.insert(message)
        if result.firstViolationAt == nil { result.firstViolationAt = net.clock.currentTime }
        result.violations.append(String(format: "t=%.1f ", net.clock.currentTime) + message)
    }

    // MARK: Run

    func run() -> StressResult {
        scheduleEvents()
        a.connect(to: b, path: path)
        if let offset = scenario.connectOffset {
            if offset <= 0 {
                b.connect(to: a, path: path)
            } else {
                _ = net.clock.schedule(delay: offset) { [weak self] in
                    guard let self else { return }
                    // Only if B has not already answered A's call.
                    if self.b.session(with: self.a, path: self.path)?.state != .connected {
                        self.b.connect(to: self.a, path: self.path)
                    }
                }
            }
        }

        let step: TimeInterval = 0.5
        let stallLimit: TimeInterval = 900
        while net.clock.currentTime < scenario.timeLimit {
            net.clock.advance(by: step)
            checkStreams()
            pumpTraffic()
            noteProgress()
            if finished() { break }
            if net.clock.currentTime - lastProgressAt > stallLimit {
                violation("no progress and no failure for \(Int(stallLimit)) s (deadlock): \(describeStates())")
                break
            }
        }
        if net.clock.currentTime >= scenario.timeLimit {
            violation("time limit reached: \(describeStates())")
        }
        finish()
        return result
    }

    private func scheduleEvents() {
        for event in scenario.events {
            switch event {
            case .disconnect(let at, let station):
                _ = net.clock.schedule(delay: at) { [weak self] in
                    guard let self else { return }
                    self.stations[station].disconnect(from: self.peer(of: station), path: self.path)
                    self.disconnectRequestedAt = self.net.clock.currentTime
                }
            case .restart(let at, let station, let reconnect):
                _ = net.clock.schedule(delay: at) { [weak self] in
                    guard let self else { return }
                    self.stations[station].restart()
                    if reconnect {
                        self.stations[station].connect(to: self.peer(of: station), path: self.path)
                    }
                }
            case .power(let at, let station, let on):
                _ = net.clock.schedule(delay: at) { [weak self] in
                    guard let self else { return }
                    self.net.channel.setPowered(self.stations[station].node, on)
                }
            }
        }
    }

    private func connected(_ i: Int) -> AX25Session? {
        guard let s = stations[i].session(with: peer(of: i), path: path), Self.isUp(s) else { return nil }
        return s
    }

    /// Up as the layer above sees it. A session establishing the link again
    /// after an unexpected UA is internally connecting, but the AX.25 2.2 SDL
    /// tells layer 3 nothing until that ends (live test log, bug 39), so the
    /// application still has its link. Counting it as down ended runs a
    /// moment after the re-establishing SABM went out.
    static func isUp(_ s: AX25Session) -> Bool {
        s.state == .connected || (s.state == .connecting && s.isReestablishing)
    }

    private func pumpTraffic() {
        guard disconnectRequestedAt == nil else { return }
        let now = net.clock.currentTime
        for i in 0..<2 {
            guard let session = connected(i), connected(1 - i) != nil else { continue }
            if pendingBulk[i] > 0, session.pendingDataQueue.count < 4 {
                let size = min(pendingBulk[i], Int(trafficRng.next() % 700) + 1)
                let data = Data((0..<size).map { _ in UInt8(truncatingIfNeeded: trafficRng.next()) })
                if stations[i].send(data, to: peer(of: i), path: path) {
                    pendingBulk[i] -= size
                    if firstWriteAt == nil { firstWriteAt = now }
                }
            }
            if chatLinesLeft[i] > 0, now >= nextChatAt[i] {
                let length = Int(trafficRng.next() % 70) + 8
                var line = Data((0..<length).map { _ in UInt8(0x20 + trafficRng.next() % 0x5F) })
                line.append(0x0D)
                if stations[i].send(line, to: peer(of: i), path: path) {
                    chatLinesLeft[i] -= 1
                    if firstWriteAt == nil { firstWriteAt = now }
                }
                if case .chat(_, let gap, _) = scenario.traffic {
                    nextChatAt[i] = now - gap * log(max(1e-9, 1 - trafficRng.nextDouble()))
                }
            }
        }
    }

    /// What each side has received must always be a prefix of what the
    /// other sent.
    private func checkStreams() {
        for i in 0..<2 {
            let receiver = stations[1 - i]
            let sender = stations[i]
            let epochs = [sender.sendEpoch[receiver.address.display] ?? 0,
                          receiver.receiveEpoch[sender.address.display] ?? 0]
            if epochs != checkedEpochs[i] {
                checkedEpochs[i] = epochs
                checkedPrefix[i] = 0
                gapFlushed[i] = false
            }
            let got = receiver.receivedStream(from: sender)
            let sent = sender.sentStream(to: receiver)
            if gapFlushed[i] { continue }
            if got.count > sent.count {
                violation("\(receiver.name) received \(got.count) bytes but \(sender.name) sent only \(sent.count) (duplicated data)")
                gapFlushed[i] = true
                continue
            }
            let from = min(checkedPrefix[i], got.count)
            if !gapFlushed[i], got.count > from,
               got[got.startIndex + from ..< got.endIndex] != sent[sent.startIndex + from ..< sent.startIndex + got.count] {
                let mismatch = (from..<got.count).first { got[got.startIndex + $0] != sent[sent.startIndex + $0] } ?? from
                let message = "\(receiver.name) stream differs from \(sender.name)'s at byte \(mismatch) of \(got.count) (lost, duplicated or reordered data)"
                if receiver.gapFlushes.contains(where: { $0.peer == sender.address.display }) {
                    // The receive-gap flush skipped a frame on purpose (a
                    // documented deviation in AX25StateMachine). Counted and
                    // reported apart from the invariant failures.
                    gapFlushed[i] = true
                    result.gapFlushLosses.append(String(format: "t=%.1f ", net.clock.currentTime) + message)
                } else {
                    violation(message)
                    // One report per broken stream: the rest of it is offset.
                    gapFlushed[i] = true
                }
            }
            checkedPrefix[i] = got.count
        }
    }

    private var deliveredTotal: Int {
        (b.received[a.address.display]?.count ?? 0) + (a.received[b.address.display]?.count ?? 0)
    }

    private func noteProgress() {
        for station in stations {
            for reset in station.silentResets.dropFirst(silentResetsSeen[station.name] ?? 0) {
                violation("\(station.name) took a link reset from \(reset.peer) and threw away \(reset.outstanding) unacknowledged frame(s) without telling the application (AX.25 2.2 SDL, appendix C4, connected state: discard the I queue and give DL-CONNECT indication when V(S) != V(A))")
            }
            silentResetsSeen[station.name] = station.silentResets.count
        }
        let delivered = deliveredTotal
        let changes = a.stateLog.count + b.stateLog.count
        if delivered != lastDelivered || changes != lastStateLogCount {
            if delivered != lastDelivered { lastDeliveryAt = net.clock.currentTime }
            lastDelivered = delivered
            lastStateLogCount = changes
            lastProgressAt = net.clock.currentTime
        }
        // A TNC backlog of a couple of windows happens when T1 runs out while
        // our own burst is still queued or on the air (T1 counts from the
        // hand-off to the TNC) and is reported as data. One that keeps
        // growing is a storm.
        for (node, depth) in net.channel.stats.maxQueueDepth.sorted(by: { $0.key < $1.key }) where depth > 64 {
            violation("\(net.channel.nodes[node].name)'s TNC queue reached more than 64 frames (retransmission storm)")
        }
    }

    private var allWritten: Bool {
        pendingBulk.allSatisfy { $0 == 0 } && chatLinesLeft.allSatisfy { $0 == 0 }
    }

    private func everythingDelivered() -> Bool {
        for i in 0..<2 where !gapFlushed[i] {
            let sent = stations[i].sentStream(to: peer(of: i))
            let got = peer(of: i).receivedStream(from: stations[i])
            if got.count != sent.count { return false }
        }
        return true
    }

    private func quiescent(_ i: Int) -> Bool {
        guard let s = connected(i) else { return false }
        return s.outstandingCount == 0 && s.pendingDataQueue.isEmpty
    }

    private func everConnected(_ i: Int) -> Bool {
        stations[i].stateLog.contains { $0.to == .connected }
    }

    private func finished() -> Bool {
        let now = net.clock.currentTime
        let up = (0..<2).map { connected($0) != nil }
        // A link that went down after coming up: let both sides notice, then stop.
        if (everConnected(0) || everConnected(1)), !up[0] || !up[1] {
            if failureSeenAt == nil { failureSeenAt = now }
            if !up[0] && !up[1] { return true }
            // The other side has its T3 and N2 polls to notice: allow them.
            return now - (failureSeenAt ?? now) > 1200
        }
        failureSeenAt = nil
        // The connect itself failed: reported as a failed link.
        if !everConnected(0), !everConnected(1),
           let s = a.session(with: b, path: path), s.state == .error || s.state == .disconnected,
           a.stateLog.contains(where: { $0.from == .connecting }) {
            return true
        }
        // The application is done and hung up, but the link came back: the
        // peer's link layer was still establishing it again after an
        // unexpected UA, answered the DISC with DM as the SDL says, and A
        // accepted its next SABM (fuzz seed 1270). Hang up again, as an
        // operator would.
        if dataDone, scenario.disconnectAtEnd, up[0], up[1], quiescent(0), quiescent(1),
           let asked = disconnectRequestedAt, now - asked > 60 {
            a.disconnect(from: b, path: path)
            disconnectRequestedAt = now
            return false
        }
        guard scenario.events.isEmpty || disconnectRequestedAt == nil else { return false }
        if !dataDone, allWritten, everythingDelivered(), quiescent(0), quiescent(1) {
            dataDone = true
            result.completed = true
            if scenario.disconnectAtEnd {
                a.disconnect(from: b, path: path)
                disconnectRequestedAt = now
                return false
            }
            return true
        }
        return false
    }

    private func describeStates() -> String {
        (0..<2).map { i -> String in
            guard let s = stations[i].session(with: peer(of: i), path: path) else { return "\(stations[i].name): none" }
            return "\(stations[i].name): \(s.state.rawValue) vs=\(s.vs) va=\(s.va) vr=\(s.vr) out=\(s.outstandingCount) q=\(s.pendingDataQueue.count) retry=\(s.stateMachine.retryCount)"
        }.joined(separator: "; ")
    }

    // MARK: End of run

    private func finish() {
        checkStreams()
        let up = (0..<2).map { stations[$0].session(with: peer(of: $0), path: path).map(Self.isUp) ?? false }
        result.linkFailed = !result.completed
            && ((0..<2).contains { everConnected($0) && !up[$0] }
                || (!everConnected(0) && !everConnected(1)))

        if result.completed {
            if !everythingDelivered(), result.gapFlushLosses.isEmpty {
                violation("completed without delivering everything")
            }
            if scenario.disconnectAtEnd, up[0] || up[1] {
                violation("graceful disconnect did not finish: \(describeStates())")
            }
        } else if result.linkFailed {
            // Both sides must have said so.
            for i in 0..<2 where everConnected(i) {
                if up[i] {
                    violation("\(stations[i].name) still connected after the other side failed: \(describeStates())")
                }
                // A station that crashed reported it by crashing.
                if stations[i].restarts == 0,
                   !stations[i].stateLog.contains(where: { $0.from == .connected && $0.to != .connected }) {
                    violation("\(stations[i].name) never reported the link going down")
                }
            }
        }

        if up[0] && up[1], let sa = connected(0), let sb = connected(1),
           quiescent(0), quiescent(1) {
            if sa.vs != sb.vr || sa.vr != sb.vs {
                violation("sequence state disagrees at rest: A vs=\(sa.vs) vr=\(sa.vr), B vs=\(sb.vs) vr=\(sb.vr)")
            }
        }

        let downTimes = stations.compactMap { st in
            st.stateLog.first(where: { $0.from == .connected && $0.to != .connected })?.time
        }
        if downTimes.count == 2 { result.failureLag = abs(downTimes[0] - downTimes[1]) }

        let stats = net.channel.stats
        result.elapsed = net.clock.currentTime
        result.dataTime = max(0, lastDeliveryAt - (firstWriteAt ?? lastDeliveryAt))
        result.bytesDelivered = deliveredTotal
        result.newIFrames = a.newIFrames + b.newIFrames
        result.retransmittedIFrames = a.retransmittedIFrames + b.retransmittedIFrames
        result.collisions = stats.collisions
        result.deafLosses = stats.deafLosses
        result.transmissions = stats.transmissions
        result.timers = a.metrics + b.metrics
        result.midBurstT2Lost = SimReception.allCases.filter { $0 != .delivered }
            .reduce(0) { $0 + net.outcomeCount(.t2AckMidBurst, $1) }
        result.t2AcksLost = result.midBurstT2Lost + SimReception.allCases.filter { $0 != .delivered }
            .reduce(0) { $0 + net.outcomeCount(.t2Ack, $1) }
        result.maxQueueDepth = stats.maxQueueDepth.values.max() ?? 0
        result.trace = net.channel.trace
        result.unexpectedUAs = a.unexpectedUAs.count + b.unexpectedUAs.count
        result.firstUnexpectedUA = (a.unexpectedUAs + b.unexpectedUAs).min()
        for station in [a, b] {
            let log = station.stateLog
            for (down, up) in zip(log, log.dropFirst())
            where down.from == .connected && down.to == .disconnected
                && up.from == .disconnected && up.to == .connected && up.time == down.time {
                result.resetIndications.append(down.time)
            }
        }
        result.fingerprint = [
            String(format: "%.3f", result.elapsed), "\(result.bytesDelivered)", "\(result.newIFrames)",
            "\(result.retransmittedIFrames)", "\(stats.framesOnAir)", "\(stats.collisions)",
            "\(stats.deafLosses)", "\(result.timers.t1Batches)", "\(result.timers.t2Acks)",
            net.channel.trace.suffix(20).joined(separator: "|")
        ].joined(separator: ",")
    }
}

// MARK: - Aggregates for reporting

struct StressTally {
    var runs = 0
    var completed = 0
    var failed = 0
    var bytes = 0
    var dataTime: TimeInterval = 0
    var newI = 0
    var retx = 0
    var collisions = 0
    var deaf = 0
    var timers = SimTimerMetrics()
    var midBurstLost = 0
    var gapFlushRuns = 0
    var maxQueue = 0
    var backlogRuns = 0

    mutating func add(_ r: StressResult) {
        runs += 1
        maxQueue = max(maxQueue, r.maxQueueDepth)
        if r.maxQueueDepth > 24 { backlogRuns += 1 }
        if !r.gapFlushLosses.isEmpty { gapFlushRuns += 1 }
        if r.completed { completed += 1 }
        if r.linkFailed { failed += 1 }
        bytes += r.bytesDelivered
        dataTime += r.dataTime
        newI += r.newIFrames
        retx += r.retransmittedIFrames
        collisions += r.collisions
        deaf += r.deafLosses
        timers = timers + r.timers
        midBurstLost += r.midBurstT2Lost
    }

    mutating func merge(_ o: StressTally) {
        runs += o.runs; completed += o.completed; failed += o.failed
        bytes += o.bytes; dataTime += o.dataTime; newI += o.newI; retx += o.retx
        collisions += o.collisions; deaf += o.deaf; timers = timers + o.timers
        midBurstLost += o.midBurstLost; gapFlushRuns += o.gapFlushRuns
        maxQueue = max(maxQueue, o.maxQueue); backlogRuns += o.backlogRuns
    }

    /// Delivered data rate across the tallied runs.
    var bps: Double { dataTime > 0 ? Double(bytes * 8) / dataTime : 0 }

    var row: String {
        let ratio = newI > 0 ? Double(retx) / Double(newI) : 0
        return String(format: "runs %d ok %d failed %d gapflush %d | %.0f bps | retx %.3f | coll %d deaf %d | T1 %d early %d (own %d, peerT2 %d, ackInFlight %d) ackLost %d needed %d | T2 %d mid-burst %d (lost %d) | tnc max %d, runs over 24: %d",
                      runs, completed, failed, gapFlushRuns, bps, ratio, collisions, deaf,
                      timers.t1Batches, timers.earlyT1, timers.earlyT1OwnBurst, timers.earlyT1PeerT2,
                      timers.earlyT1AckInFlight, timers.spuriousT1AckLost, timers.neededT1,
                      timers.t2Acks, timers.midBurstT2, midBurstLost, maxQueue, backlogRuns)
    }
}

// MARK: - Report file

/// The stress report, written where a test run can be read back from: the
/// test host's temporary directory, `AXTermStress/<name>.txt`.
enum StressReport {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AXTermStress", isDirectory: true)
    }

    static func write(_ lines: [String], name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
