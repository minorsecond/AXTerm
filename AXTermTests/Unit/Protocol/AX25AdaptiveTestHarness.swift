//
//  AX25AdaptiveTestHarness.swift
//  AXTermTests
//
//  Deterministic two-node AX.25 test harness for adaptive validation.
//
//  Design:
//    - Alice and Bob share a single AX25VirtualClock for deterministic ordering.
//    - All inter-node frame delivery is scheduled via the virtual clock (no Task.sleep).
//    - An RFImpairmentModel and seeded RFRng control what happens to each frame.
//    - AdaptiveSnapshot is captured at every significant protocol event.
//    - AdaptiveInvariantChecker runs after every clock advance.
//    - All failures emit a replay trace with seed + impairment timeline.
//
//  Usage pattern:
//    let harness = AdaptiveTestHarness(seed: 42, model: BurstLossModel.shortBurst())
//    harness.connect()
//    harness.sendFrames(count: 20, payload: Data("ping".utf8))
//    harness.advance(seconds: 30)
//    let violations = harness.invariantViolations
//    let stability  = harness.stabilityScore
//

import Foundation
import XCTest
@testable import AXTerm

// MARK: - Node Identity

enum HarnessNode {
    case alice
    case bob
}

// MARK: - Harness Configuration

struct HarnessConfig {
    /// Simulation seed — determines all RF outcomes reproducibly.
    var seed: UInt64 = 42

    /// Base one-way RF propagation delay (seconds).
    var baseLatency: TimeInterval = 0.1

    /// Impairment applied to Alice → Bob frames.
    var forwardModel: any RFImpairmentModel = PerfectChannelModel()

    /// Impairment applied to Bob → Alice frames (ACK path).
    var reverseModel: any RFImpairmentModel = PerfectChannelModel()

    /// AX.25 session config for both nodes.
    var sessionConfig: AX25SessionConfig = AX25SessionConfig(
        windowSize: 4,
        paclen: 128,
        maxRetries: 6,
        rtoMin: 1.0,
        rtoMax: 16.0,
        initialRto: 2.0
    )

    /// Whether to run AdaptiveInvariantChecker after each clock advance.
    var checkInvariantsAutomatically: Bool = true

    /// Snapshot capture triggers (capture after every matching event).
    var captureOnEveryRR: Bool = true
    var captureOnEveryT1: Bool = true
    var captureOnEveryREJ: Bool = true
}

// MARK: - Harness Statistics

struct HarnessStats {
    var aliceFramesSent: Int = 0
    var bobFramesSent: Int = 0
    var aliceFramesDropped: Int = 0
    var bobFramesDropped: Int = 0
    var aliceFramesDuplicated: Int = 0
    var bobFramesDuplicated: Int = 0
    var totalClockAdvance: TimeInterval = 0
    var bytesDeliveredToAlice: Int = 0
    var bytesDeliveredToBob: Int = 0
}

// MARK: - Adaptive Test Harness

/// Two-node deterministic protocol harness for adaptive AX.25 testing.
///
/// Architecture:
///   alice ──[forwardModel]──▶ bob
///   alice ◀──[reverseModel]── bob
///
/// The harness intercepts all `onSendFrame` callbacks and schedules delivery
/// through the virtual clock, applying the configured impairment models.
@MainActor
final class AdaptiveTestHarness {

    // MARK: - Public API

    let alice: AX25SessionManager
    let bob: AX25SessionManager
    let clock: AX25VirtualClock
    let config: HarnessConfig

    private(set) var trace: AdaptiveTrace
    private(set) var stats: HarnessStats = HarnessStats()
    private(set) var invariantViolations: [AdaptiveInvariantChecker.Violation] = []
    private(set) var deliveredToAlice: [Data] = []
    private(set) var deliveredToBob: [Data] = []
    private(set) var throughput: ThroughputMeter = ThroughputMeter()

    // MARK: - Private State

    private let aliceAddr = AX25Address(call: "ALICE-1", ssid: 0)
    private let bobAddr   = AX25Address(call: "BOB-1", ssid: 0)
    private let path      = DigiPath([])

    private var rng: RFRng
    private var forwardModel: any RFImpairmentModel
    private var reverseModel: any RFImpairmentModel
    private let invariantChecker: AdaptiveInvariantChecker

    // MARK: - Init

    init(config: HarnessConfig = HarnessConfig()) {
        self.config = config
        self.rng    = RFRng(seed: config.seed)
        self.forwardModel = config.forwardModel
        self.reverseModel = config.reverseModel
        self.clock  = AX25VirtualClock()
        self.trace  = AdaptiveTrace(seed: config.seed)
        self.invariantChecker = AdaptiveInvariantChecker()

        alice = AX25SessionManager(
            localCallsign: AX25Address(call: "ALICE-1", ssid: 0),
            clock: clock
        )
        alice.defaultConfig = config.sessionConfig

        bob = AX25SessionManager(
            localCallsign: AX25Address(call: "BOB-1", ssid: 0),
            clock: clock
        )
        bob.defaultConfig = config.sessionConfig

        throughput.start(at: 0)
        wireCallbacks()
    }

    // MARK: - Session Control

    /// Alice initiates a connection to Bob and the harness automatically exchanges SABM/UA.
    @discardableResult
    func connect() -> Bool {
        // 1. Alice sends SABM — returned directly from connect()
        guard let sabm = alice.connect(to: bobAddr, path: path, channel: 0) else {
            return false
        }

        // 2. Deliver SABM to Bob immediately (no impairment on handshake for simplicity)
        if let ua = bob.handleInboundSABM(from: aliceAddr, to: bobAddr, path: path, channel: 0) {
            // Bob sends UA back to Alice
            deliverToAlice(frame: ua, delay: config.baseLatency)
        }

        // 3. Advance past the handshake latency so UA reaches Alice
        clock.advance(by: config.baseLatency + 0.01)

        let aliceSession = alice.session(for: bobAddr, path: path, channel: 0)
        captureSnapshot(session: aliceSession, context: "connected", trigger: .uaReceived)

        _ = sabm  // suppress unused-result warning
        return aliceSession.state == .connected
    }

    /// Alice disconnects gracefully.
    func disconnect() {
        let session = alice.existingSession(for: bobAddr, path: path, channel: 0)
        if let session = session {
            _ = alice.disconnect(session: session)
        }
    }

    // MARK: - Data Transmission

    /// Alice sends `count` I-frames of the given payload and we advance the clock enough
    /// for the full exchange (ACKs included) to complete under zero-loss conditions.
    func sendFrames(
        count: Int,
        payload: Data = Data("adaptive-test".utf8),
        advanceFactor: TimeInterval = 1.5
    ) {
        let rto = alice.existingSession(for: bobAddr, path: path, channel: 0)?.timers.rto ?? 2.0
        for _ in 0..<count {
            let frames = alice.sendData(payload, to: bobAddr, path: path, channel: 0)
            for f in frames {
                stats.aliceFramesSent += 1
                throughput.recordSend(bytes: payload.count, at: clock.currentTime)
                dispatchFromAlice(frame: f)
            }
        }
        // Advance enough time for the exchange to complete (RTO + base latency round-trip)
        let needed = rto * advanceFactor + config.baseLatency * 2
        clock.advance(by: needed)
    }

    /// Send data from Alice to Bob and return without advancing the clock.
    func queueFrames(count: Int, payload: Data = Data("test".utf8)) {
        for _ in 0..<count {
            let frames = alice.sendData(payload, to: bobAddr, path: path, channel: 0)
            for f in frames { dispatchFromAlice(frame: f) }
        }
    }

    /// Advance the virtual clock by `seconds`.
    /// Also runs invariant checks and captures a periodic snapshot.
    func advance(seconds: TimeInterval) {
        clock.advance(by: seconds)
        stats.totalClockAdvance += seconds

        if config.checkInvariantsAutomatically {
            runInvariantChecks()
        }

        // Periodic snapshot
        if let session = alice.existingSession(for: bobAddr, path: path, channel: 0) {
            captureSnapshot(session: session, context: "periodic", trigger: .periodic)
        }
    }

    // MARK: - Impairment Control

    /// Replace the forward impairment model mid-test (models phase changes / RF recovery).
    func setForwardModel(_ model: any RFImpairmentModel) {
        forwardModel = model
    }

    /// Replace the reverse impairment model mid-test.
    func setReverseModel(_ model: any RFImpairmentModel) {
        reverseModel = model
    }

    // MARK: - Metrics Accessors

    /// Alice's current session (nil if not connected).
    var aliceSession: AX25Session? {
        alice.existingSession(for: bobAddr, path: path, channel: 0)
    }

    /// Bob's current session (nil if not connected).
    var bobSession: AX25Session? {
        bob.existingSession(for: aliceAddr, path: path, channel: 0)
    }

    /// Current RTO for Alice's session.
    var aliceRTO: Double {
        aliceSession?.timers.rto ?? Double.nan
    }

    /// Current SRTT for Alice's session.
    var aliceSRTT: Double? {
        aliceSession?.timers.srtt
    }

    /// Compute stability score from the accumulated trace.
    var stabilityScore: StabilityScorer.StabilityScore {
        let scorer = StabilityScorer(
            rtoMin: config.sessionConfig.rtoMin ?? 1.0,
            rtoMax: config.sessionConfig.rtoMax ?? 30.0
        )
        return scorer.score(trace: trace)
    }

    // MARK: - Private — Frame Dispatch

    /// Route a frame from Alice outward, applying the forward impairment model.
    private func dispatchFromAlice(frame: OutboundFrame) {
        let disp = forwardModel.disposition(
            type: frame.frameType,
            direction: .forward,
            time: clock.currentTime,
            rng: &rng
        )
        stats.aliceFramesSent += 0  // already counted at call site
        applyDisposition(disp, frame: frame, to: .bob)
    }

    /// Route a frame from Bob outward, applying the reverse impairment model.
    private func dispatchFromBob(frame: OutboundFrame) {
        stats.bobFramesSent += 1
        let disp = reverseModel.disposition(
            type: frame.frameType,
            direction: .reverse,
            time: clock.currentTime,
            rng: &rng
        )
        applyDisposition(disp, frame: frame, to: .alice)
    }

    private func applyDisposition(
        _ disp: FrameDisposition,
        frame: OutboundFrame,
        to recipient: HarnessNode
    ) {
        switch disp {
        case .drop:
            if recipient == .bob { stats.aliceFramesDropped += 1 }
            else                 { stats.bobFramesDropped += 1 }

        case .deliver(let delay):
            scheduleDelivery(frame: frame, to: recipient, delay: max(0.001, delay))

        case .duplicate(let first, let second):
            if recipient == .bob { stats.aliceFramesDuplicated += 1 }
            else                 { stats.bobFramesDuplicated += 1 }
            scheduleDelivery(frame: frame, to: recipient, delay: max(0.001, first))
            scheduleDelivery(frame: frame, to: recipient, delay: max(0.001, second))
        }
    }

    private func scheduleDelivery(frame: OutboundFrame, to recipient: HarnessNode, delay: TimeInterval) {
        _ = clock.schedule(delay: delay) { [weak self] in
            guard let self = self else { return }
            switch recipient {
            case .alice: self.deliverToAliceDirect(frame: frame)
            case .bob:   self.deliverToBobDirect(frame: frame)
            }
        }
    }

    // Immediate delivery (for initial SABM/UA handshake)
    private func deliverToAlice(frame: OutboundFrame, delay: TimeInterval) {
        scheduleDelivery(frame: frame, to: .alice, delay: delay)
    }

    // MARK: - Private — Protocol Dispatch

    private func deliverToBobDirect(frame: OutboundFrame) {
        let responses = dispatchToBob(frame: frame)
        for r in responses { dispatchFromBob(frame: r) }
    }

    private func deliverToAliceDirect(frame: OutboundFrame) {
        let responses = dispatchToAlice(frame: frame)
        for r in responses { dispatchFromAlice(frame: r) }
    }

    /// Deliver a frame to Bob's protocol stack and return any response frames.
    private func dispatchToBob(frame: OutboundFrame) -> [OutboundFrame] {
        let from = frame.source
        let channel: UInt8 = frame.channel
        let path = frame.path.normalized
        var responses: [OutboundFrame] = []

        switch frame.frameType.lowercased() {
        case "u":
            let info = frame.displayInfo ?? ""
            if info.contains("SABM") {
                if let r = bob.handleInboundSABM(from: from, to: frame.destination, path: path, channel: channel) {
                    responses.append(r)
                }
            } else if info.contains("UA") {
                bob.handleInboundUA(from: from, path: path, channel: channel)
            } else if info.contains("DM") {
                bob.handleInboundDM(from: from, path: path, channel: channel)
            } else if info.contains("DISC") {
                if let r = bob.handleInboundDISC(from: from, path: path, channel: channel) {
                    responses.append(r)
                }
            }

        case "i":
            if let r = bob.handleInboundIFrame(
                from: from, path: path, channel: channel,
                ns: frame.ns ?? 0, nr: frame.nr ?? 0, pf: false,
                payload: frame.payload
            ) {
                responses.append(r)
            }
            deliveredToBob.append(frame.payload)
            throughput.recordDelivery(bytes: frame.payload.count, at: clock.currentTime)

        case "s":
            let info = frame.displayInfo ?? ""
            if info.hasPrefix("RR") || info.hasPrefix("rr") {
                if let r = bob.handleInboundRR(
                    from: from, path: path, channel: channel,
                    nr: frame.nr ?? 0, isPoll: false
                ) {
                    responses.append(r)
                }
            } else if info.hasPrefix("REJ") || info.hasPrefix("rej") {
                let frames = bob.handleInboundREJ(from: from, path: path, channel: channel, nr: frame.nr ?? 0)
                responses.append(contentsOf: frames)
            }

        default:
            break
        }

        return responses
    }

    /// Deliver a frame to Alice's protocol stack and return any response frames.
    private func dispatchToAlice(frame: OutboundFrame) -> [OutboundFrame] {
        let from = frame.source
        let channel: UInt8 = frame.channel
        let path = frame.path.normalized
        var responses: [OutboundFrame] = []

        switch frame.frameType.lowercased() {
        case "u":
            let info = frame.displayInfo ?? ""
            if info.contains("UA") {
                alice.handleInboundUA(from: from, path: path, channel: channel)
                if let session = aliceSession {
                    captureSnapshot(session: session, context: "ua-received", trigger: .uaReceived)
                }
            } else if info.contains("DM") {
                alice.handleInboundDM(from: from, path: path, channel: channel)
            } else if info.contains("DISC") {
                if let r = alice.handleInboundDISC(from: from, path: path, channel: channel) {
                    responses.append(r)
                }
            }

        case "i":
            if let r = alice.handleInboundIFrame(
                from: from, path: path, channel: channel,
                ns: frame.ns ?? 0, nr: frame.nr ?? 0, pf: false,
                payload: frame.payload
            ) {
                responses.append(r)
            }
            deliveredToAlice.append(frame.payload)

        case "s":
            let info = frame.displayInfo ?? ""
            if info.hasPrefix("RR") || info.hasPrefix("rr") {
                if let r = alice.handleInboundRR(
                    from: from, path: path, channel: channel,
                    nr: frame.nr ?? 0, isPoll: false
                ) {
                    responses.append(r)
                }
                if config.captureOnEveryRR, let session = aliceSession {
                    captureSnapshot(session: session, context: "rr-received", trigger: .rrReceived)
                }
            } else if info.hasPrefix("REJ") || info.hasPrefix("rej") {
                let frames = alice.handleInboundREJ(from: from, path: path, channel: channel, nr: frame.nr ?? 0)
                responses.append(contentsOf: frames)
                if config.captureOnEveryREJ, let session = aliceSession {
                    captureSnapshot(session: session, context: "rej-received", trigger: .rejReceived)
                }
            }

        default:
            break
        }

        return responses
    }

    // MARK: - Private — Callbacks

    private func wireCallbacks() {
        // Alice sends → forward impairment → Bob
        alice.onSendFrame = { [weak self] frame in
            guard let self = self else { return }
            self.dispatchFromAlice(frame: frame)
        }

        // Bob sends → reverse impairment → Alice
        bob.onSendFrame = { [weak self] frame in
            guard let self = self else { return }
            self.dispatchFromBob(frame: frame)
        }

        // Deliver data to test harness
        alice.onDataReceived = { [weak self] _, data in
            self?.deliveredToAlice.append(data)
        }
        bob.onDataReceived = { [weak self] _, data in
            self?.deliveredToBob.append(data)
            self?.throughput.recordDelivery(bytes: data.count, at: self?.clock.currentTime ?? 0)
        }
    }

    // MARK: - Private — Metrics & Invariants

    private func captureSnapshot(
        session: AX25Session,
        context: String,
        trigger: AdaptiveTrigger
    ) {
        let snap = AdaptiveSnapshot.capture(
            from: session,
            at: clock.currentTime,
            context: context,
            trigger: trigger
        )
        trace.append(snap)
    }

    private func runInvariantChecks() {
        let checker = AdaptiveInvariantChecker()
        if let session = aliceSession {
            let violations = checker.check(session: session, context: "t=\(clock.currentTime)")
            invariantViolations.append(contentsOf: violations)
        }
        if let session = bobSession {
            let violations = checker.check(session: session, context: "bob t=\(clock.currentTime)")
            invariantViolations.append(contentsOf: violations)
        }
    }
}

// MARK: - Multi-Session Harness (Fairness Testing)

/// Extends the basic harness to support multiple simultaneous sessions from Alice,
/// each on a different channel / peer, with independent impairment models.
@MainActor
final class MultisessionAdaptiveHarness {

    struct SessionEntry {
        let peerAddr: AX25Address
        let channel: UInt8
        var forwardModel: any RFImpairmentModel
        var reverseModel: any RFImpairmentModel
        var deliveredPayloads: [Data] = []
        var rng: RFRng
    }

    let clock: AX25VirtualClock
    let alice: AX25SessionManager
    private(set) var sessions: [SessionEntry] = []
    private(set) var invariantViolations: [AdaptiveInvariantChecker.Violation] = []

    private let aliceAddr = AX25Address(call: "ALICE-0", ssid: 0)
    private let checker = AdaptiveInvariantChecker()

    init(sessionConfig: AX25SessionConfig = AX25SessionConfig()) {
        self.clock = AX25VirtualClock()
        self.alice = AX25SessionManager(
            localCallsign: AX25Address(call: "ALICE-0", ssid: 0),
            clock: clock
        )
        alice.defaultConfig = sessionConfig
    }

    /// Add a new session to a peer with a given impairment model.
    func addSession(
        peer: String,
        channel: UInt8,
        forwardModel: any RFImpairmentModel,
        reverseModel: any RFImpairmentModel,
        seed: UInt64
    ) {
        let addr = AX25Address(call: peer, ssid: 0)
        sessions.append(SessionEntry(
            peerAddr: addr,
            channel: channel,
            forwardModel: forwardModel,
            reverseModel: reverseModel,
            rng: RFRng(seed: seed)
        ))
    }

    /// Connect all registered sessions.
    func connectAll() {
        for entry in sessions {
            _ = alice.connect(to: entry.peerAddr, path: DigiPath(), channel: entry.channel)
        }
    }

    func advance(seconds: TimeInterval) {
        clock.advance(by: seconds)
        // Run invariant checks for all Alice sessions
        for entry in sessions {
            if let session = alice.existingSession(for: entry.peerAddr, path: DigiPath(), channel: entry.channel) {
                let violations = checker.check(session: session)
                invariantViolations.append(contentsOf: violations)
            }
        }
    }
}
