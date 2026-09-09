import XCTest
@testable import AXTerm

/// What the radio's own settings say about its ability to hear packet.
///
/// The comparison against the APRS-IS feed on 2026-09-09 showed K0EPI-7
/// hearing strong signals and missing ordinary ones. Two of the four things
/// that cause that live in the radio, not the software, and the radio will
/// tell us over CI-V if we ask — which is cheaper than an afternoon of
/// swapping antennas.
final class RigReceiveAuditTests: XCTestCase {

    private func settings(attenuatorDB: Int = 0, preamp: Int = 1,
                          noiseBlanker: Bool = false, noiseReduction: Bool = false,
                          rfGainPercent: Int = 100, squelchPercent: Int = 0,
                          mode: RigMode = .fm, filter: Int = 1,
                          dataMode: Bool = true) -> RigReceiveAudit.Settings {
        .init(attenuatorDB: attenuatorDB, preamp: preamp, noiseBlanker: noiseBlanker,
              noiseReduction: noiseReduction, rfGainPercent: rfGainPercent,
              squelchPercent: squelchPercent, mode: mode, filter: filter, dataMode: dataMode)
    }

    /// A radio set up properly has nothing to say.
    func testAWellSetUpRadioRaisesNothing() {
        XCTAssertTrue(RigReceiveAudit.findings(settings()).isEmpty)
    }

    /// The attenuator is the one that would produce exactly the symptom: 10 dB
    /// straight off the front end, so the mountaintop digis still crash in and
    /// the mobile at 10 km disappears.
    func testTheAttenuatorIsReportedAsBlocking() throws {
        let f = try XCTUnwrap(RigReceiveAudit.findings(settings(attenuatorDB: 10)).first)
        XCTAssertEqual(f.severity, .blocking)
        XCTAssertTrue(f.detail.contains("10 dB"), f.detail)
        XCTAssertFalse(f.fix.isEmpty, "a finding the operator cannot act on is noise")
    }

    /// RF gain backed off does the same thing more quietly, and is easy to
    /// leave behind after chasing a noisy band.
    func testRFGainBelowFullIsReported() throws {
        let f = try XCTUnwrap(RigReceiveAudit.findings(settings(rfGainPercent: 60)).first)
        XCTAssertEqual(f.severity, .blocking)
        XCTAssertTrue(f.detail.contains("60"), f.detail)
    }

    /// Noise reduction and the noise blanker both reshape the audio the
    /// demodulator is trying to read. They help a human ear and hurt a modem.
    func testNoiseProcessingIsReportedAsDegrading() {
        let nr = RigReceiveAudit.findings(settings(noiseReduction: true))
        let nb = RigReceiveAudit.findings(settings(noiseBlanker: true))
        XCTAssertEqual(nr.first?.severity, .degrading)
        XCTAssertEqual(nb.first?.severity, .degrading)
    }

    /// A narrow FM filter clips 1200-baud AFSK, which needs the wide one.
    func testANarrowFMFilterIsReported() throws {
        let f = try XCTUnwrap(RigReceiveAudit.findings(settings(filter: 3)).first)
        XCTAssertEqual(f.severity, .blocking)
        XCTAssertTrue(f.title.lowercased().contains("filter"), f.title)
    }

    /// The wrong mode entirely is worth saying plainly rather than leaving the
    /// operator to infer it from silence.
    func testANonFMModeIsReported() throws {
        let f = try XCTUnwrap(RigReceiveAudit.findings(settings(mode: .usb)).first)
        XCTAssertEqual(f.severity, .blocking)
    }

    /// Squelch is the one the operator already checked, so the audit must
    /// agree with them when it is open and only complain when it is not.
    func testAnOpenSquelchIsNotComplainedAbout() {
        XCTAssertTrue(RigReceiveAudit.findings(settings(squelchPercent: 0)).isEmpty)
        XCTAssertEqual(RigReceiveAudit.findings(settings(squelchPercent: 40)).first?.severity,
                       .blocking)
    }

    /// Blocking findings come first: an operator reading a list acts on the
    /// top of it.
    func testBlockingFindingsAreListedFirst() {
        let all = RigReceiveAudit.findings(
            settings(attenuatorDB: 10, noiseReduction: true, squelchPercent: 40))
        XCTAssertGreaterThanOrEqual(all.count, 3)
        XCTAssertEqual(all.first?.severity, .blocking)
        XCTAssertEqual(all.last?.severity, .degrading)
    }

    // MARK: - Not knowing is not the same as nothing being wrong

    /// The failure that made this necessary: `auditReceive` returned an empty
    /// list both when the radio was healthy and when we could not ask it, so a
    /// dead CI-V link reported "nothing is holding receive back" — the most
    /// reassuring possible way to say "I have no idea". An operator acting on
    /// that would go and buy an antenna.
    func testAnEmptyResultIsNotAnAnswer() {
        XCTAssertTrue(RigReceiveAudit.Result.checked([]).isAnswer)
        XCTAssertFalse(RigReceiveAudit.Result.unavailable("no CI-V").isAnswer)
    }

    /// And each says something different to the operator.
    func testTheTwoOutcomesReadDifferently() {
        let fine = RigReceiveAudit.Result.checked([]).summary
        let unknown = RigReceiveAudit.Result.unavailable("the CI-V link is not open").summary
        XCTAssertNotEqual(fine, unknown)
        XCTAssertTrue(unknown.lowercased().contains("ci-v"), unknown)
        XCTAssertFalse(fine.lowercased().contains("could not"), fine)
    }

    /// A result with findings counts them rather than listing them twice —
    /// the rows below say what they are.
    func testAResultWithFindingsSaysHowMany() {
        let result = RigReceiveAudit.Result.checked(RigReceiveAudit.findings(settings(attenuatorDB: 10)))
        XCTAssertTrue(result.isAnswer)
        XCTAssertTrue(result.summary.lowercased().contains("receive range"), result.summary)
    }

    // MARK: - Noticing a change mid-session

    /// The radio is the operator's, and they use it. Somebody turns on NR to
    /// listen to a weak voice signal and forgets; the packet station quietly
    /// gets worse and nothing says so. The watch reports what is newly wrong,
    /// not the standing state — a list repeated every two minutes is not a
    /// warning, it is wallpaper.
    func testOnlyNewFaultsAreReported() {
        let before = RigReceiveAudit.findings(settings(attenuatorDB: 10))
        let after = RigReceiveAudit.findings(settings(attenuatorDB: 10, noiseReduction: true))
        let new = RigReceiveAudit.newFindings(from: before, to: after)
        XCTAssertEqual(new.map(\.title), ["Noise reduction is on"],
                       "the attenuator was already known about")
    }

    func testNothingNewIsReportedWhenNothingChanged() {
        let f = RigReceiveAudit.findings(settings(attenuatorDB: 10))
        XCTAssertTrue(RigReceiveAudit.newFindings(from: f, to: f).isEmpty)
    }

    /// A fault going away is not something to announce, but it must not leave
    /// the watch thinking it is still there — otherwise it can never be
    /// reported again if it returns.
    func testAClearedFaultCanBeReportedAgainIfItReturns() {
        let bad = RigReceiveAudit.findings(settings(noiseReduction: true))
        let good = RigReceiveAudit.findings(settings())
        XCTAssertTrue(RigReceiveAudit.newFindings(from: bad, to: good).isEmpty)
        XCTAssertEqual(RigReceiveAudit.newFindings(from: good, to: bad).count, 1)
    }

    // MARK: - Fixing, not just reporting

    /// Every fault the audit names, it can also correct — that is the whole
    /// point of owning the radio as well as the modem. A finding with advice
    /// and no lever behind it is a chore handed back to the operator.
    func testEveryBlockingFindingCarriesACorrection() {
        let bad = settings(attenuatorDB: 10, noiseBlanker: true, noiseReduction: true,
                           rfGainPercent: 50, squelchPercent: 40, filter: 3)
        let findings = RigReceiveAudit.findings(bad)
        XCTAssertEqual(findings.count, 6)
        for finding in findings where finding.severity != .suggestion {
            XCTAssertNotNil(finding.correction, "\(finding.title) has nothing behind it")
        }
    }

    /// The preamp is the exception, deliberately: it is a judgement about the
    /// band, not a fault, and turning it on unasked is a decision that is not
    /// ours to make.
    func testASuggestionIsNotCorrectedAutomatically() {
        XCTAssertNil(RigReceiveAudit.findings(settings(preamp: 0)).first?.correction)
    }

    /// The wrong mode is named but not changed. The operator may be listening
    /// to something on purpose, and taking the radio off their voice QSO to
    /// fix packet is not a trade we get to make for them.
    func testTheModeIsReportedButNeverChanged() throws {
        let f = try XCTUnwrap(RigReceiveAudit.findings(settings(mode: .usb)).first)
        XCTAssertNil(f.correction, "changing the operator's mode is their call")
    }

    /// A radio that is already right needs nothing done to it.
    func testNothingToFixOnAGoodRadio() {
        XCTAssertTrue(RigReceiveAudit.findings(settings()).compactMap(\.correction).isEmpty)
    }

    /// The preamp being off is a suggestion, not a fault — it is the right
    /// setting on a crowded band and costs only a little on 2 m.
    func testThePreampOffIsOnlyASuggestion() {
        XCTAssertEqual(RigReceiveAudit.findings(settings(preamp: 0)).first?.severity, .suggestion)
    }
}
