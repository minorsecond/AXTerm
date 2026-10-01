//
//  InSessionLinkGrowthTests.swift
//  AXTermTests
//
//  K and paclen move during a session (live RF test 2026-09-30, improvement
//  I-1; spec §7.8.1).
//
//  The field session ran 14 minutes at K=2 paclen 128 with no retransmissions,
//  because the session's starting K was also its ceiling and paclen was fixed
//  for the session. Now a session has ceilings fixed at creation (the most the
//  link allows: the peer's XID k and N1, K=4, paclen 256 direct and one rung
//  less per digipeater) and live values that start at the last confirmed
//  values, grow after a clean streak, and halve on loss.
//
//  The rules that keep sequence state safe while they move:
//  - a larger K waits until nothing is outstanding;
//  - a smaller K applies at once (it only stops new frames);
//  - a new paclen applies only to data segmented after the change.
//

import XCTest
@testable import AXTerm

// MARK: - The controller

final class InSessionLinkControllerTests: XCTestCase {

    /// The window ladder stops at the link's ceiling, the way paclen stops at
    /// the hop ceiling. A peer that advertised k=3 never sees a probe at 4.
    func testWindowCeilingCapsGrowthEvenTransiently() {
        var settings = TxAdaptiveSettings()
        settings.applyLinkCeilings(window: 3, paclen: 256)

        var maxWindowSeen = settings.windowSize.currentAdaptive
        for _ in 0..<200 {
            settings.updateFromLinkQuality(lossRate: 0, etx: 1, srtt: nil,
                                           newFrames: 1, retransmits: 0)
            maxWindowSeen = max(maxWindowSeen, settings.windowSize.currentAdaptive)
        }

        XCTAssertEqual(maxWindowSeen, 3)
        XCTAssertEqual(settings.paclen.currentAdaptive, 256,
                       "the paclen ladder is independent of the window ceiling")
    }

    /// Lowering the ceilings clamps values already learned above them.
    func testLowerCeilingsClampLearnedValues() {
        var settings = TxAdaptiveSettings()
        for _ in 0..<200 {
            settings.updateFromLinkQuality(lossRate: 0, etx: 1, srtt: nil,
                                           newFrames: 1, retransmits: 0)
        }
        XCTAssertEqual(settings.windowSize.currentAdaptive, 4, "precondition")
        XCTAssertEqual(settings.paclen.currentAdaptive, 256, "precondition")

        settings.applyLinkCeilings(window: 2, paclen: 128)

        XCTAssertEqual(settings.windowSize.currentAdaptive, 2)
        XCTAssertEqual(settings.paclen.currentAdaptive, 128)
    }

    /// No evidence of frames in flight keeps the original fixed five seconds,
    /// so every existing caller behaves as before.
    func testRoundTripAllowanceWithoutBytesInFlightIsTheFixedCeiling() {
        XCTAssertEqual(TxAdaptiveSettings.upgradeSrttAllowance(bytesInFlight: nil),
                       TxAdaptiveSettings.upgradeSrttCeiling)
        XCTAssertEqual(TxAdaptiveSettings.upgradeSrttAllowance(bytesInFlight: 0),
                       TxAdaptiveSettings.upgradeSrttCeiling)
    }

    /// Our own frames' airtime is part of the measured round trip, so it is
    /// added to the allowance: 292 bytes at 1200 bps is 1.95 s.
    func testRoundTripAllowanceAddsOurOwnAirtime() {
        let allowance = TxAdaptiveSettings.upgradeSrttAllowance(bytesInFlight: 292)
        XCTAssertEqual(allowance, 5.0 + 292.0 * 8.0 / 1200.0, accuracy: 0.0001)
    }

    /// The 2026-09-30 link: about 2.6 s of fixed overhead plus the airtime of
    /// the window. A fixed 5 s ceiling stalls it at the first rung, because a
    /// bigger window lengthens the round trip by exactly its own airtime.
    func testFieldLinkGrowsToTheTopWhenTheRoundTripIsItsOwnAirtime() {
        var settings = TxAdaptiveSettings()
        for _ in 0..<200 {
            let k = settings.windowSize.currentAdaptive
            let p = settings.paclen.currentAdaptive
            let bytes = k * (p + 18)
            let srtt = 2.6 + Double(bytes) * 8.0 / 1200.0
            settings.updateFromLinkQuality(lossRate: 0, etx: 1, srtt: srtt,
                                           newFrames: 1, retransmits: 0,
                                           bytesInFlight: bytes)
        }
        XCTAssertEqual(settings.windowSize.currentAdaptive, 4)
        XCTAssertEqual(settings.paclen.currentAdaptive, 256)
    }

    /// The slow-link guard still holds: 12 s of overhead never earns a rung,
    /// whatever is in flight.
    func testSlowLinkStillNeverEarnsAnUpgradeWithAirtimeAllowance() {
        var settings = TxAdaptiveSettings()
        for _ in 0..<200 {
            let bytes = settings.windowSize.currentAdaptive * (settings.paclen.currentAdaptive + 18)
            settings.updateFromLinkQuality(lossRate: 0, etx: 1,
                                           srtt: 12.0 + Double(bytes) * 8.0 / 1200.0,
                                           newFrames: 1, retransmits: 0,
                                           bytesInFlight: bytes)
        }
        XCTAssertEqual(settings.windowSize.currentAdaptive, 2)
        XCTAssertEqual(settings.paclen.currentAdaptive, 128)
    }

    /// A probe on trial is not confirmed: the confirmed values are the ones
    /// it would roll back to.
    func testConfirmedValuesExcludeAProbeOnTrial() {
        var settings = TxAdaptiveSettings()
        for _ in 0..<10 {
            settings.updateFromLinkQuality(lossRate: 0, etx: 1, srtt: nil,
                                           newFrames: 1, retransmits: 0)
        }
        XCTAssertNotNil(settings.probation, "precondition: a probe is on trial")
        XCTAssertEqual(settings.windowSize.currentAdaptive, 3)
        XCTAssertEqual(settings.confirmedWindow, 2)
        XCTAssertEqual(settings.confirmedPaclen, 128)

        for _ in 0..<10 {
            settings.updateFromLinkQuality(lossRate: 0, etx: 1, srtt: nil,
                                           newFrames: 1, retransmits: 0)
        }
        XCTAssertNil(settings.probation, "precondition: the trial passed")
        XCTAssertEqual(settings.confirmedWindow, 3)
        XCTAssertEqual(settings.confirmedPaclen, 192)
    }
}

// MARK: - The session layer

@MainActor
final class InSessionLinkManagerTests: XCTestCase {

    private var manager: AX25SessionManager!
    private var clock: AX25VirtualClock!
    private var drained: [OutboundFrame] = []
    private let peer = AX25Address(call: "PEER", ssid: 0)

    override func setUp() {
        super.setUp()
        clock = AX25VirtualClock()
        manager = AX25SessionManager(localCallsign: AX25Address(call: "LOCAL", ssid: 0), clock: clock)
        manager.xidMemory = XIDAnswerMemory(defaults: TestDefaults.make("InSessionLinkManagerTests"))
        manager.defaultConfig = growable(window: 2, paclen: 128)
        drained = []
        manager.onSendFrame = { [weak self] frame in self?.drained.append(frame) }
    }

    override func tearDown() {
        manager = nil
        clock = nil
        super.tearDown()
    }

    private func growable(window: Int, paclen: Int,
                          maxWindow: Int = 4, maxPaclen: Int = 256) -> AX25SessionConfig {
        AX25SessionConfig(windowSize: window, paclen: paclen,
                          rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0,
                          maxWindowSize: maxWindow, maxPaclen: maxPaclen)
    }

    private func connected(path: DigiPath = DigiPath()) -> AX25Session {
        _ = manager.connect(to: peer, path: path, radio: .primary)
        manager.handleInboundUA(from: peer, path: path, radio: .primary)
        let session = manager.session(for: peer, path: path, radio: .primary)
        XCTAssertEqual(session.state, .connected, "precondition: connected")
        return session
    }

    @discardableResult
    private func send(_ text: String, path: DigiPath = DigiPath()) -> [OutboundFrame] {
        manager.sendData(Data(text.utf8), to: peer, path: path, radio: .primary)
    }

    private func send(bytes count: Int) -> [OutboundFrame] {
        manager.sendData(Data(repeating: 0x41, count: count), to: peer, path: DigiPath(), radio: .primary)
    }

    // MARK: Start and ceilings

    func testSessionStartsAtItsStartValuesWithRoomToGrow() {
        let session = connected()
        XCTAssertEqual(session.liveWindowSize, 2)
        XCTAssertEqual(session.livePaclen, 128)
        XCTAssertEqual(session.stateMachine.config.windowCeiling, 4)
        XCTAssertEqual(session.stateMachine.config.paclenCeiling, 256)
        XCTAssertEqual(session.aimdWindow.effectiveWindow, 2,
                       "the congestion window starts at the live K, not the ceiling")
    }

    /// A config without ceilings is the classic fixed session: targets are
    /// ignored.
    func testFixedConfigIgnoresTargets() {
        manager.defaultConfig = AX25SessionConfig(windowSize: 2, paclen: 128,
                                                  rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0)
        let session = connected()
        manager.updateLinkTargets(for: session, window: 4, paclen: 256, reason: "test")
        XCTAssertEqual(session.liveWindowSize, 2)
        XCTAssertEqual(session.livePaclen, 128)
    }

    func testTargetsAreClampedToTheCeilings() {
        manager.defaultConfig = growable(window: 2, paclen: 128, maxWindow: 3, maxPaclen: 192)
        let session = connected()
        manager.updateLinkTargets(for: session, window: 7, paclen: 256, reason: "test")
        XCTAssertEqual(session.liveWindowSize, 3)
        XCTAssertEqual(session.livePaclen, 192)
    }

    // MARK: The quiescent point

    /// A larger K decided while frames are outstanding waits. The send gate
    /// stays at the old K until everything in flight is acknowledged.
    func testLargerWindowWaitsUntilNothingIsOutstanding() {
        let session = connected()
        send("one")
        send("two")
        XCTAssertEqual(session.outstandingCount, 2, "precondition: window full")

        manager.updateLinkTargets(for: session, window: 3, paclen: 128, reason: "test")
        XCTAssertEqual(session.liveWindowSize, 2, "frames are outstanding: K must not move yet")
        XCTAssertEqual(session.pendingWindowSize, 3)

        let frames = send("three")
        XCTAssertTrue(frames.isEmpty, "the old K still gates new frames")
        XCTAssertEqual(session.outstandingCount, 2)
        send("four")

        // Partial ack: one frame still outstanding, still not quiescent.
        manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary,
                                nr: (session.va + 1) % 8)
        XCTAssertEqual(session.liveWindowSize, 2, "one frame still outstanding")
        XCTAssertEqual(session.outstandingCount, 2, "the drain refilled the old window only")

        // Everything acknowledged: the raise takes effect before the drain.
        drained = []
        manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary, nr: session.vs)
        XCTAssertEqual(session.liveWindowSize, 3)
        XCTAssertNil(session.pendingWindowSize)
        XCTAssertEqual(session.outstandingCount, 1, "the one queued frame went out under the new K")
        manager.checkInvariants(session: session)
    }

    /// With nothing outstanding the raise applies immediately.
    func testLargerWindowAppliesAtOnceWhenIdle() {
        let session = connected()
        manager.updateLinkTargets(for: session, window: 4, paclen: 128, reason: "test")
        XCTAssertEqual(session.liveWindowSize, 4)
        XCTAssertNil(session.pendingWindowSize)
        XCTAssertEqual(session.aimdWindow.effectiveWindow, 4)
    }

    /// Backing off is immediate: lowering the gate only stops new frames, and
    /// the congestion window is capped so the next loss cuts below it.
    func testSmallerWindowAppliesAtOnceWithFramesOutstanding() {
        manager.defaultConfig = growable(window: 4, paclen: 128)
        let session = connected()
        for i in 0..<4 { send("f\(i)") }
        XCTAssertEqual(session.outstandingCount, 4, "precondition")

        manager.updateLinkTargets(for: session, window: 2, paclen: 128, reason: "loss")
        XCTAssertEqual(session.liveWindowSize, 2)
        XCTAssertLessThanOrEqual(session.aimdWindow.effectiveWindow, 2)
        XCTAssertEqual(session.outstandingCount, 4, "frames in flight are left alone")
        manager.checkInvariants(session: session)

        // Acks for two frames free nothing: outstanding 2 equals the new K.
        send("queued")
        manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary,
                                nr: (session.va + 2) % 8)
        XCTAssertEqual(session.outstandingCount, 2)
    }

    /// A raise waiting for quiescence is dropped when the target falls back.
    func testPendingRaiseIsCanceledByALowerTarget() {
        let session = connected()
        send("one"); send("two")
        manager.updateLinkTargets(for: session, window: 4, paclen: 128, reason: "test")
        XCTAssertEqual(session.pendingWindowSize, 4)
        manager.updateLinkTargets(for: session, window: 2, paclen: 128, reason: "test")
        XCTAssertNil(session.pendingWindowSize)
        manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary, nr: session.vs)
        XCTAssertEqual(session.liveWindowSize, 2)
    }

    // MARK: Paclen and segmentation

    /// Data already cut into frames keeps its size; only data segmented after
    /// the change uses the new paclen.
    func testNewPaclenAppliesOnlyToDataSegmentedAfterIt() {
        manager.defaultConfig = growable(window: 1, paclen: 128)
        let session = connected()

        let first = send(bytes: 300)
        XCTAssertEqual(first.map(\.payload.count), [128])
        XCTAssertEqual(session.pendingDataQueue.map(\.data.count), [128, 44])

        manager.updateLinkTargets(for: session, window: 1, paclen: 256, reason: "test")
        XCTAssertEqual(session.livePaclen, 256)
        XCTAssertEqual(session.pendingDataQueue.map(\.data.count), [128, 44],
                       "queued data is not re-cut")
        XCTAssertEqual(session.sendBuffer.values.map(\.payload.count), [128],
                       "the frame in flight is not re-cut")

        _ = send(bytes: 300)
        XCTAssertEqual(session.pendingDataQueue.map(\.data.count), [128, 44, 256, 44])

        // Drain everything one frame at a time and check the order on the air.
        var onAir = first.map(\.payload.count)
        for _ in 0..<4 {
            drained = []
            manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary, nr: session.vs)
            onAir += drained.filter { $0.frameType == "i" }.map(\.payload.count)
        }
        XCTAssertEqual(onAir, [128, 128, 44, 256, 44])
    }

    /// A retransmission resends the frame as it was built.
    func testRetransmissionKeepsTheOriginalFrameSize() {
        manager.defaultConfig = growable(window: 1, paclen: 128)
        let session = connected()
        _ = send(bytes: 200)
        manager.updateLinkTargets(for: session, window: 1, paclen: 64, reason: "loss")
        XCTAssertEqual(session.livePaclen, 64)

        let resent = manager.handleT1Timeout(session: session)
            .filter { $0.frameType == "i" }
        XCTAssertFalse(resent.isEmpty, "precondition: T1 expiry retransmits")
        XCTAssertEqual(resent.map(\.payload.count), [128])
    }

    /// One NET/ROM datagram is one I-frame. A datagram sized before paclen
    /// fell still goes out whole: it is within what the peer accepted.
    func testNetRomDatagramIsNeverSplitWhenPaclenFalls() {
        let session = connected()
        manager.updateLinkTargets(for: session, window: 2, paclen: 64, reason: "loss")
        let frames = manager.sendData(Data(repeating: 0x01, count: 100), to: peer,
                                      path: DigiPath(), radio: .primary, pid: 0xCF)
        XCTAssertEqual(frames.map(\.payload.count), [100])
    }

    // MARK: XID ceiling

    private func xidResponse(n1: Int?, k: Int?) -> Data {
        var params = AX25XIDParameters()
        params.supportsSREJ = false
        params.iFieldLengthRx = n1
        params.windowSizeRx = k
        return params.encoded(isCommand: false)
    }

    /// We advertise what we can receive (the ceilings), and growth never
    /// exceeds what the peer advertised.
    func testGrowthNeverExceedsWhatThePeerAdvertisedInXID() {
        manager.negotiateV22 = true
        let xid = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(xid?.displayInfo, "XID")
        let offered = xid.flatMap { AX25XIDParameters.parse($0.payload) }
        XCTAssertEqual(offered?.windowSizeRx, 4, "our k is the ceiling we can receive")
        XCTAssertEqual(offered?.iFieldLengthRx, 256, "our N1 is the ceiling we can receive")

        _ = manager.handleInboundXID(from: peer, path: DigiPath(), radio: .primary,
                                     info: xidResponse(n1: 192, k: 3), isCommand: false, pf: true)
        manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.stateMachine.config.windowCeiling, 3)
        XCTAssertEqual(session.stateMachine.config.paclenCeiling, 192)
        XCTAssertEqual(session.liveWindowSize, 2, "the start is below the peer's k")

        manager.updateLinkTargets(for: session, window: 4, paclen: 256, reason: "test")
        XCTAssertEqual(session.liveWindowSize, 3, "never above the peer's k")
        XCTAssertEqual(session.livePaclen, 192, "never above the peer's N1")
    }

    /// A peer advertising less than our start lowers the start too.
    func testPeerXIDBelowTheStartLowersTheStart() {
        manager.negotiateV22 = true
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundXID(from: peer, path: DigiPath(), radio: .primary,
                                     info: xidResponse(n1: 64, k: 1), isCommand: false, pf: true)
        manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.liveWindowSize, 1)
        XCTAssertEqual(session.livePaclen, 64)
        XCTAssertEqual(session.stateMachine.config.windowCeiling, 1)
        XCTAssertEqual(session.stateMachine.config.paclenCeiling, 64)
    }

    // MARK: Multi-session merge

    /// Two sessions to one station run the smaller of what either would
    /// choose; when one ends, the other is free to grow again.
    /// The peer calls us through a digipeater while our direct link to it
    /// is up: the usual way two sessions to one station on one radio exist.
    private func inboundSession(path: DigiPath) -> AX25Session {
        _ = manager.handleInboundSABM(from: peer, to: AX25Address(call: "LOCAL", ssid: 0),
                                      path: path, radio: .primary)
        let session = manager.existingSession(for: peer, path: path, radio: .primary)
        XCTAssertEqual(session?.state, .connected, "precondition: the inbound session is up")
        return session!
    }

    func testTwoSessionsToOneStationRunTheConservativeMergedValues() {
        let viaPath = DigiPath.from(["DIGI-1"])
        let direct = connected()
        let via = inboundSession(path: viaPath)

        manager.updateLinkTargets(for: direct, window: 4, paclen: 256, reason: "test")
        XCTAssertEqual(direct.liveWindowSize, 2, "the via session has not moved from 2")
        XCTAssertEqual(direct.livePaclen, 128)

        manager.updateLinkTargets(for: via, window: 3, paclen: 192, reason: "test")
        XCTAssertEqual(direct.liveWindowSize, 3)
        XCTAssertEqual(direct.livePaclen, 192)
        XCTAssertEqual(via.liveWindowSize, 3)
        XCTAssertEqual(via.livePaclen, 192)

        // The via session ends; the direct one grows to its own choice.
        _ = manager.disconnect(session: via)
        manager.updateLinkTargets(for: direct, window: 4, paclen: 256, reason: "test")
        XCTAssertEqual(direct.liveWindowSize, 4)
        XCTAssertEqual(direct.livePaclen, 256)
    }

    // MARK: Observability

    func testLiveChangesAreAnnounced() {
        let session = connected()
        var announced: [(Int, Int)] = []
        manager.onLiveLinkChanged = { s in announced.append((s.liveWindowSize, s.livePaclen)) }
        manager.updateLinkTargets(for: session, window: 3, paclen: 192, reason: "test")
        XCTAssertEqual(announced.last?.0, 3)
        XCTAssertEqual(announced.last?.1, 192)
    }

    // MARK: Bytes in flight for the round-trip gate

    func testSampleCarriesThePeakBytesInFlight() {
        let session = connected()
        var samples: [LinkQualitySample] = []
        manager.onLinkQualitySample = { _, sample in samples.append(sample) }
        _ = send(bytes: 100)
        _ = send(bytes: 50)
        manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary, nr: session.vs)
        XCTAssertEqual(samples.last?.peakBytesInFlight, (100 + 18) + (50 + 18))
    }
}

// MARK: - The coordinator

@MainActor
final class InSessionLinkCoordinatorTests: XCTestCase {

    private let peer = AX25Address(call: "PEER", ssid: 0)

    private func makeCoordinator() -> SessionCoordinator {
        let coordinator = SessionCoordinator()
        coordinator.adaptiveTransmissionEnabled = true
        coordinator.inSessionLinkGrowth = true
        coordinator.localCallsign = "LOCAL-0"
        return coordinator
    }

    /// Off by default since 2026-10-01 (bursts longer than the receiver's T2
    /// collided with its acks): a session keeps the K and paclen it started
    /// with unless growth is switched on.
    func testGrowthIsOffByDefault() {
        let coordinator = SessionCoordinator()
        coordinator.adaptiveTransmissionEnabled = true
        coordinator.localCallsign = "LOCAL-0"
        XCTAssertFalse(coordinator.inSessionLinkGrowth)
        let config = coordinator.sessionManager.getConfigForDestination?("PEER-0", "", .primary)
        XCTAssertEqual(config?.adaptsInSession, false, "a session got growth ceilings with growth off")
    }

    override func tearDown() {
        SessionCoordinator.shared = nil
        super.tearDown()
    }

    private func connect(_ coordinator: SessionCoordinator, path: DigiPath = DigiPath()) -> AX25Session {
        _ = coordinator.sessionManager.connect(to: peer, path: path, radio: .primary)
        coordinator.sessionManager.handleInboundUA(from: peer, path: path, radio: .primary)
        return coordinator.sessionManager.session(for: peer, path: path, radio: .primary)
    }

    private func clean(_ coordinator: SessionCoordinator, _ session: AX25Session, times: Int = 1) {
        for _ in 0..<times {
            coordinator.sessionManager.onLinkQualitySample?(session, LinkQualitySample(
                lossRate: 0, forwardLoss: 0, reverseLoss: 0, etx: 1, srtt: nil,
                newFrames: 1, retransmits: 0))
        }
    }

    private func retransmission(_ coordinator: SessionCoordinator, _ session: AX25Session) {
        coordinator.sessionManager.onLinkQualitySample?(session, LinkQualitySample(
            lossRate: 0.1, forwardLoss: 0.1, reverseLoss: 0, etx: 1.2, srtt: nil,
            newFrames: 0, retransmits: 1))
    }

    private var directScope: AdaptiveScope {
        .route(radio: .primary, destination: "PEER-0", path: "")
    }

    // MARK: Ceilings in the config

    func testConfigCarriesTheHopCeilingAndTheWindowCap() {
        let coordinator = makeCoordinator()
        let config = { (path: String) in
            coordinator.sessionManager.getConfigForDestination?("PEER-0", path, .primary)
                ?? AX25SessionConfig()
        }
        XCTAssertEqual(config("").maxPaclen, 256)
        XCTAssertEqual(config("DIGI-1").maxPaclen, 192)
        XCTAssertEqual(config("DIGI-1,DIGI-2").maxPaclen, 128)
        XCTAssertEqual(config("").maxWindowSize, 4)
        XCTAssertEqual(config("").windowSize, 2, "with nothing learned, start at K=2")
        XCTAssertEqual(config("").paclen, 128, "with nothing learned, start at paclen 128")
    }

    /// Manual K or paclen stays exactly what the operator set: no room to grow.
    func testManualValuesDoNotGrow() {
        let coordinator = makeCoordinator()
        coordinator.globalAdaptiveSettings.windowSize.mode = .manual
        coordinator.globalAdaptiveSettings.windowSize.manualValue = 3
        let config = coordinator.sessionManager.getConfigForDestination?("PEER-0", "", .primary)
        XCTAssertEqual(config?.windowSize, 3)
        XCTAssertNil(config?.maxWindowSize)
        XCTAssertEqual(config?.maxPaclen, 256, "paclen is still on Auto")
    }

    func testAdaptiveOffMeansFixedSessions() {
        let coordinator = makeCoordinator()
        coordinator.adaptiveTransmissionEnabled = false
        let config = coordinator.sessionManager.getConfigForDestination?("PEER-0", "", .primary)
        XCTAssertNil(config?.maxWindowSize)
        XCTAssertNil(config?.maxPaclen)
    }

    // MARK: Growth and backoff through real samples

    /// The streak earns a rung, the session runs it on trial, and only a
    /// passed trial is remembered for next time.
    func testCleanStreakGrowsTheLiveSessionThroughProbation() {
        let coordinator = makeCoordinator()
        let session = connect(coordinator)
        XCTAssertEqual(session.liveWindowSize, 2)
        XCTAssertEqual(session.livePaclen, 128)

        clean(coordinator, session, times: 9)
        XCTAssertEqual(session.liveWindowSize, 2, "nine clean frames are not a streak")

        clean(coordinator, session)
        XCTAssertEqual(session.liveWindowSize, 3)
        XCTAssertEqual(session.livePaclen, 192)
        XCTAssertNil(coordinator.confirmedLinkMemory.values(for: directScope),
                     "a probe on trial is not remembered")

        clean(coordinator, session, times: 10)
        XCTAssertEqual(coordinator.confirmedLinkMemory.values(for: directScope)?.window, 3)
        XCTAssertEqual(coordinator.confirmedLinkMemory.values(for: directScope)?.paclen, 192)

        clean(coordinator, session)
        XCTAssertEqual(session.liveWindowSize, 4)
        XCTAssertEqual(session.livePaclen, 256)

        clean(coordinator, session, times: 40)
        XCTAssertEqual(session.liveWindowSize, 4, "K=4 is the top at 1200 baud")
        XCTAssertEqual(session.livePaclen, 256)
    }

    /// A retransmission halves K and steps paclen down at once, and lowers
    /// what is remembered.
    func testLossHalvesTheLiveWindowAtOnce() {
        let coordinator = makeCoordinator()
        let session = connect(coordinator)
        clean(coordinator, session, times: 31)
        XCTAssertEqual(session.liveWindowSize, 4, "precondition")
        XCTAssertEqual(coordinator.confirmedLinkMemory.values(for: directScope)?.window, 4)

        retransmission(coordinator, session)
        XCTAssertEqual(session.liveWindowSize, 2)
        XCTAssertEqual(session.livePaclen, 192)
        XCTAssertEqual(coordinator.confirmedLinkMemory.values(for: directScope)?.window, 2,
                       "a backoff lowers what the next session starts from")
        XCTAssertEqual(coordinator.confirmedLinkMemory.values(for: directScope)?.paclen, 192)
    }

    /// The hop ceiling holds through growth on a digipeated route.
    func testHopCeilingHoldsThroughGrowth() {
        let coordinator = makeCoordinator()
        let session = connect(coordinator, path: DigiPath.from(["DIGI-1"]))
        clean(coordinator, session, times: 100)
        XCTAssertEqual(session.livePaclen, 192)
        XCTAssertEqual(session.liveWindowSize, 4)
    }

    /// Two sessions to one station: the merged config at creation, and the
    /// merged values while both are open.
    func testSecondSessionToTheSameStationRunsMergedValues() {
        let coordinator = makeCoordinator()
        let direct = connect(coordinator)
        clean(coordinator, direct, times: 31)
        XCTAssertEqual(direct.liveWindowSize, 4, "precondition")

        // The peer calls us through a digipeater while the direct link is up.
        let viaPath = DigiPath.from(["DIGI-1"])
        _ = coordinator.sessionManager.handleInboundSABM(
            from: peer, to: AX25Address(call: "LOCAL", ssid: 0), path: viaPath, radio: .primary)
        guard let via = coordinator.sessionManager.existingSession(for: peer, path: viaPath, radio: .primary) else {
            return XCTFail("precondition: the inbound session exists")
        }
        XCTAssertEqual(via.state, .connected, "precondition")
        XCTAssertEqual(via.stateMachine.config.startSource, .merged)
        clean(coordinator, direct)
        XCTAssertEqual(direct.liveWindowSize, via.liveWindowSize,
                       "while both are open they run the same, smaller window")
        XCTAssertLessThan(direct.liveWindowSize, 4)
    }

    // MARK: Seeding

    /// With growth off, a session starts the way it did before §7.8.1:
    /// confirmed-link memory is neither read nor written.
    func testWithGrowthOffConfirmedMemoryDoesNotSeedTheStart() {
        let coordinator = makeCoordinator()
        coordinator.inSessionLinkGrowth = false
        coordinator.confirmedLinkMemory.recordConfirmed(
            window: 4, paclen: 256, for: directScope, at: Date().addingTimeInterval(-3600))

        let config = coordinator.sessionManager.getConfigForDestination?("PEER-0", "", .primary)
        XCTAssertNotEqual(config?.windowSize, 4, "growth off, but the start came from confirmed memory")
        XCTAssertNotEqual(config?.paclen, 256)
    }

    func testSessionStartsAtValuesConfirmedWithinADay() {
        let coordinator = makeCoordinator()
        coordinator.confirmedLinkMemory.recordConfirmed(
            window: 4, paclen: 256, for: directScope, at: Date().addingTimeInterval(-3600))

        let config = coordinator.sessionManager.getConfigForDestination?("PEER-0", "", .primary)
        XCTAssertEqual(config?.windowSize, 4)
        XCTAssertEqual(config?.paclen, 256)
        if case .confirmed = config?.startSource {} else {
            XCTFail("the start names where it came from, got \(String(describing: config?.startSource))")
        }

        // The session runs from there, and the first clean sample does not
        // knock it back to the defaults.
        let session = connect(coordinator)
        XCTAssertEqual(session.liveWindowSize, 4)
        clean(coordinator, session)
        XCTAssertEqual(session.liveWindowSize, 4)
        XCTAssertEqual(session.livePaclen, 256)
    }

    func testConfirmedValuesOlderThanADayAreIgnored() {
        let coordinator = makeCoordinator()
        coordinator.confirmedLinkMemory.recordConfirmed(
            window: 4, paclen: 256, for: directScope, at: Date().addingTimeInterval(-25 * 3600))
        let config = coordinator.sessionManager.getConfigForDestination?("PEER-0", "", .primary)
        XCTAssertEqual(config?.windowSize, 2)
        XCTAssertEqual(config?.paclen, 128)
        XCTAssertEqual(config?.startSource, .configured)
    }

    /// Keyed by path: what a digipeated path confirmed says nothing about the
    /// direct path, and the other way around.
    func testConfirmedValuesAreKeyedByPath() {
        let coordinator = makeCoordinator()
        coordinator.confirmedLinkMemory.recordConfirmed(
            window: 4, paclen: 256, for: directScope, at: Date())
        let via = coordinator.sessionManager.getConfigForDestination?("PEER-0", "DIGI-1", .primary)
        XCTAssertEqual(via?.windowSize, 2)
        XCTAssertEqual(via?.paclen, 128)
    }

    /// Clear All Learned clears the memory too.
    func testClearAllLearnedForgetsConfirmedValues() {
        let coordinator = makeCoordinator()
        coordinator.confirmedLinkMemory.recordConfirmed(window: 4, paclen: 256, for: directScope, at: Date())
        coordinator.clearAllLearned()
        XCTAssertNil(coordinator.confirmedLinkMemory.values(for: directScope))
    }

    // MARK: Determinism

    private func trajectory() -> [String] {
        let coordinator = makeCoordinator()
        let session = connect(coordinator)
        var steps: [String] = []
        let script: [Bool] = Array(repeating: true, count: 25) + [false]
            + Array(repeating: true, count: 30) + [false, false] + Array(repeating: true, count: 40)
        for isClean in script {
            if isClean { clean(coordinator, session) } else { retransmission(coordinator, session) }
            steps.append("K\(session.liveWindowSize) P\(session.livePaclen)")
        }
        return steps
    }

    func testSameEvidenceGivesTheSameTrajectory() {
        let first = trajectory()
        let second = trajectory()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first[9], "K3 P192")
        XCTAssertEqual(first[20], "K4 P256", "the second probe")
        XCTAssertEqual(first[25], "K2 P192",
                       "a retransmission during the second trial halves K and rolls paclen back")
    }

    // MARK: Display

    /// The status bar shows the session's live values.
    func testStatusBarShowsTheLiveValues() {
        let coordinator = makeCoordinator()
        let session = connect(coordinator)
        coordinator.selectAdaptiveSession(destination: "PEER-0", path: "", radio: .primary)
        clean(coordinator, session, times: 10)
        let shown = coordinator.adaptiveStatusStore.effectiveAdaptive
        XCTAssertEqual(shown?.displayK, session.liveWindowSize)
        XCTAssertEqual(shown?.displayP, session.livePaclen)
        XCTAssertNotNil(shown?.live)
    }
}

// MARK: - Memory and display helpers

final class ConfirmedLinkMemoryTests: XCTestCase {

    private let scope = AdaptiveScope.route(radio: .primary, destination: "peer-0", path: "")

    func testRecordsAndExpiresAfterADay() {
        var memory = ConfirmedLinkMemory()
        let then = Date(timeIntervalSince1970: 1_000_000)
        memory.recordConfirmed(window: 3, paclen: 192, for: scope, at: then)
        XCTAssertEqual(memory.values(for: scope, now: then.addingTimeInterval(23 * 3600))?.window, 3)
        XCTAssertNil(memory.values(for: scope, now: then.addingTimeInterval(24 * 3600 + 1)))
    }

    func testLoweringOnlyLowersAndOnlyWhatExists() {
        var memory = ConfirmedLinkMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        memory.lower(window: 1, paclen: 64, for: scope, at: now)
        XCTAssertNil(memory.values(for: scope, now: now), "a backoff alone is not a confirmation")

        memory.recordConfirmed(window: 3, paclen: 192, for: scope, at: now)
        memory.lower(window: 4, paclen: 128, for: scope, at: now)
        XCTAssertEqual(memory.values(for: scope, now: now)?.window, 3, "lowering never raises")
        XCTAssertEqual(memory.values(for: scope, now: now)?.paclen, 128)
    }

    func testChannelScopesAreNotRemembered() {
        var memory = ConfirmedLinkMemory()
        memory.recordConfirmed(window: 3, paclen: 192, for: .radio(.primary), at: Date())
        XCTAssertNil(memory.values(for: .radio(.primary)))
    }

    func testPersistsWhenGivenStorage() {
        let defaults = TestDefaults.make("ConfirmedLinkMemoryTests")
        let now = Date()
        var memory = ConfirmedLinkMemory(defaults: defaults)
        memory.recordConfirmed(window: 3, paclen: 192, for: scope, at: now)

        let reopened = ConfirmedLinkMemory(defaults: defaults)
        XCTAssertEqual(reopened.values(for: scope, now: now)?.window, 3)
        XCTAssertEqual(reopened.values(for: scope, now: now)?.paclen, 192)
    }

    func testLiveExplanationSaysWhyTheValueIsWhatItIs() {
        let live = AdaptiveLiveLink(k: 2, p: 128, windowCeiling: 4, paclenCeiling: 192,
                                    pendingK: 3, startSource: .configured,
                                    reason: "Stable link: probing larger frames")
        let text = live.explanation
        XCTAssertTrue(text.contains("K2"), text)
        XCTAssertTrue(text.contains("up to 4"), text)
        XCTAssertTrue(text.contains("up to 192"), text)
        XCTAssertTrue(text.contains("K3"), "names the raise that is waiting: \(text)")
        XCTAssertTrue(text.contains("Stable link"), text)
    }
}
