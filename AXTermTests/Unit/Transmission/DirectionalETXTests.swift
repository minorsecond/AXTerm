import XCTest
@testable import AXTerm

/// ETX must be `1 / (df · dr)` with the two directions measured
/// separately (CLAUDE.md §8).
///
/// The regression these guard against: ETX was computed as `1 / df²`,
/// substituting the forward delivery probability for the reverse one. On
/// a symmetric link that is harmless. On an asymmetric one — the case the
/// metric exists to catch — it reports a perfect link while half the
/// traffic is being lost. A receive-heavy session made it worse still:
/// the sample only fired on forward evidence, so a download over a lossy
/// reverse path produced no samples at all.
@MainActor
final class DirectionalETXTests: XCTestCase {

    private var manager: AX25SessionManager!
    private var samples: [LinkQualitySample] = []

    override func setUp() {
        super.setUp()
        samples = []
        manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 2))
        manager.onLinkQualitySample = { [weak self] _, sample in
            self?.samples.append(sample)
        }
    }

    override func tearDown() {
        manager = nil
        samples = []
        super.tearDown()
    }

    private func connectedSession(peer: String = "W0ARP-10") -> AX25Session {
        let parsed = CallsignNormalizer.parse(peer)
        let remote = AX25Address(call: parsed.call, ssid: parsed.ssid)
        _ = manager.handleInboundSABM(
            from: remote, to: manager.localCallsign, path: DigiPath(), channel: 0)
        return manager.existingSession(for: remote)!
    }

    /// Drives one sample by setting the statistics directly, which is how
    /// the real counters reach the sampler.
    private func emit(
        session: AX25Session,
        sent: Int, retransmits: Int, received: Int, rejSent: Int
    ) {
        session.statistics.framesSent = sent
        session.statistics.retransmissions = retransmits
        session.statistics.framesReceived = received
        session.statistics.rejSent = rejSent
        manager.emitLinkQualitySampleIfNeeded(for: session)
    }

    // MARK: - The field case

    /// W0ARP-10, 2026-08-23: 344 inbound I-frames, 16 REJs sent, and our
    /// own transmissions all landing first try. Old maths said ETX 1.00.
    func testReceiveHeavySessionWithReverseLossIsNotReportedAsPerfect() {
        let session = connectedSession()
        emit(session: session, sent: 20, retransmits: 0, received: 344, rejSent: 16)

        guard let sample = samples.last else { return XCTFail("no sample") }

        // dr = 1 − 16/360 ≈ 0.9556, df = 1.0 → ETX ≈ 1.046.
        XCTAssertGreaterThan(sample.etx, 1.0,
                             "reverse-path loss must raise ETX above a perfect link")
        XCTAssertEqual(sample.etx, 1.0 / 0.95556, accuracy: 0.01)
        XCTAssertEqual(sample.lossRate, 16.0 / 360.0, accuracy: 0.001,
                       "the reported loss is the worse direction, here the reverse")
    }

    /// The starvation half of the bug: with no I-frames of our own going
    /// out, the sampler used to emit nothing at all.
    func testPureDownloadStillProducesASample() {
        let session = connectedSession()
        session.statistics.framesSent = 1  // the sampler requires I-frame history
        session.lastSampledFramesSent = 1
        emit(session: session, sent: 1, retransmits: 0, received: 100, rejSent: 12)

        XCTAssertEqual(samples.count, 1,
                       "reverse-path evidence alone must produce a sample")
        XCTAssertGreaterThan(samples[0].etx, 1.0)
    }

    // MARK: - Directional independence

    func testForwardLossAloneRaisesETX() {
        let session = connectedSession()
        emit(session: session, sent: 8, retransmits: 2, received: 0, rejSent: 0)

        guard let sample = samples.last else { return XCTFail("no sample") }
        // df = 1 − 2/10 = 0.8; no reverse evidence, so dr falls back to df.
        XCTAssertEqual(sample.etx, 1.0 / (0.8 * 0.8), accuracy: 0.01)
        XCTAssertEqual(sample.lossRate, 0.2, accuracy: 0.001)
    }

    func testCleanLinkInBothDirectionsIsETXOne() {
        let session = connectedSession()
        emit(session: session, sent: 30, retransmits: 0, received: 30, rejSent: 0)

        guard let sample = samples.last else { return XCTFail("no sample") }
        XCTAssertEqual(sample.etx, 1.0, accuracy: 0.0001)
        XCTAssertEqual(sample.lossRate, 0.0, accuracy: 0.0001)
    }

    /// An asymmetric link is the whole point: clean one way, bad the
    /// other. `1/df²` cannot represent it; `1/(df·dr)` can.
    func testAsymmetricLinkDiffersFromTheSymmetricApproximation() {
        let session = connectedSession()
        emit(session: session, sent: 10, retransmits: 0, received: 50, rejSent: 25)

        guard let sample = samples.last else { return XCTFail("no sample") }
        // df = 1.0, dr = 1 − 25/75 ≈ 0.667 → ETX ≈ 1.5.
        XCTAssertEqual(sample.etx, 1.5, accuracy: 0.02)
        // The old symmetric maths would have reported 1/1² = 1.0.
        XCTAssertGreaterThan(sample.etx, 1.4)
    }

    // MARK: - Bounds

    func testETXIsClampedToTheSpecRange() {
        let session = connectedSession()
        // Catastrophic both ways: df and dr both floor at 0.05 → 400,
        // clamped to the spec's ceiling of 20.
        emit(session: session, sent: 1, retransmits: 200, received: 1, rejSent: 400)

        guard let sample = samples.last else { return XCTFail("no sample") }
        XCTAssertEqual(sample.etx, 20.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(sample.lossRate, 1.0)
    }

    /// Deltas, not lifetime totals: a bad patch must not haunt a link that
    /// has since recovered.
    func testSamplesReportDeltasNotCumulativeTotals() {
        let session = connectedSession()
        emit(session: session, sent: 10, retransmits: 5, received: 10, rejSent: 0)
        emit(session: session, sent: 30, retransmits: 5, received: 40, rejSent: 0)

        XCTAssertEqual(samples.count, 2)
        XCTAssertGreaterThan(samples[0].lossRate, 0.3, "first window was lossy")
        XCTAssertEqual(samples[1].lossRate, 0.0, accuracy: 0.0001,
                       "the second window was clean and must report clean")
    }

    // MARK: - The two directions travel separately

    /// Knowing the link is bad is not the same as knowing what to do about
    /// it, and only the direction says which.
    ///
    /// The composite `lossRate` is the worse of the two and still ranks
    /// routes. `forwardLoss` is what sizes paclen and K, because those are
    /// transmit-side knobs: on 2026-08-27 a session that sent five
    /// I-frames with zero retransmissions, while answering 109 inbound
    /// frames with 17 REJs, was walked down to paclen 64 and K=1 —
    /// shrinking our frames to mend theirs.
    func testForwardAndReverseLossAreReportedApart() {
        let session = connectedSession()
        // Everything we sent landed first try; a sixth of what arrived
        // needed asking for again.
        emit(session: session, sent: 5, retransmits: 0, received: 109, rejSent: 17)

        guard let sample = samples.last else { return XCTFail("no sample") }
        XCTAssertEqual(sample.forwardLoss, 0.0, accuracy: 0.0001,
                       "our frames were not the ones being lost")
        XCTAssertEqual(sample.reverseLoss, 17.0 / 126.0, accuracy: 0.001)
        XCTAssertEqual(sample.lossRate, sample.reverseLoss, accuracy: 0.0001,
                       "the composite is the worse direction")
    }

    func testForwardLossIsReportedWhenWeAreTheOnesRetransmitting() {
        let session = connectedSession()
        emit(session: session, sent: 8, retransmits: 4, received: 20, rejSent: 0)

        guard let sample = samples.last else { return XCTFail("no sample") }
        XCTAssertEqual(sample.forwardLoss, 4.0 / 12.0, accuracy: 0.001)
        XCTAssertEqual(sample.reverseLoss, 0.0, accuracy: 0.0001)
        XCTAssertEqual(sample.lossRate, sample.forwardLoss, accuracy: 0.0001)
    }

    /// End to end: the receive-heavy session must leave our own transmit
    /// parameters where it found them.
    ///
    /// Neither shrunk nor grown. Backing off is forward-only because only
    /// forward loss is something smaller frames can mend; growing consults
    /// both directions, because putting more frames on a channel that is
    /// damaging the other end's is not an improvement either.
    func testReverseLossAloneDoesNotShrinkOurFrames() {
        let session = connectedSession()
        var settings = TxAdaptiveSettings()
        let paclenBefore = settings.paclen.currentAdaptive
        let windowBefore = settings.windowSize.currentAdaptive

        // Ten windows of the 2026-08-27 shape, enough for the EWMA to
        // settle well past every downgrade threshold.
        for round in 1...10 {
            emit(session: session,
                 sent: 5 * round, retransmits: 0,
                 received: 109 * round, rejSent: 17 * round)
            guard let sample = samples.last else { return XCTFail("no sample") }
            settings.updateFromLinkQuality(
                lossRate: sample.lossRate,
                forwardLoss: sample.forwardLoss,
                etx: sample.etx,
                srtt: sample.srtt,
                newFrames: sample.newFrames,
                retransmits: sample.retransmits)
        }

        XCTAssertEqual(settings.paclen.currentAdaptive, paclenBefore)
        XCTAssertEqual(settings.windowSize.currentAdaptive, windowBefore)
        XCTAssertGreaterThan(settings.lossRateEWMA ?? 0, 0.1,
                             "the link's real condition is still recorded")
        XCTAssertEqual(settings.forwardLossEWMA ?? 1, 0.0, accuracy: 0.0001)
    }
}
