import XCTest
@testable import AXTerm

/// The notch and tone squelch checks, every combination of everything the
/// audit can see, and the watch that turns a change during the session into
/// one notice and a fix.
///
/// Written after 2026-09-30: an IC-705 with its notch on by accident
/// decoded about one APRS frame a minute on a busy channel, and the audit
/// never looked at the notch.
final class RigReceiveAuditNotchTests: XCTestCase {

    private func settings(autoNotch: Bool = false, manualNotch: Bool = false,
                          tone: RigReceiveAudit.ToneSquelchFunction = .off) -> RigReceiveAudit.Settings {
        .init(attenuatorDB: 0, preamp: 1, noiseBlanker: false, noiseReduction: false, rfGainPercent: 100,
              squelchPercent: 0, mode: .fm, filter: 1, dataMode: true,
              autoNotch: autoNotch, manualNotch: manualNotch, toneSquelch: tone)
    }

    // MARK: - Each new check

    func testTheAutoNotchIsBlockingAndSaysWhy() throws {
        let f = try XCTUnwrap(RigReceiveAudit.findings(settings(autoNotch: true), for: .afsk1200).first)
        XCTAssertEqual(f.severity, .blocking)
        XCTAssertEqual(f.correction, .autoNotchOff)
        XCTAssertTrue(f.fix.contains("two steady tones"), f.fix)
    }

    func testTheManualNotchIsDegradingAndNamesTheTones() throws {
        let fm = try XCTUnwrap(RigReceiveAudit.findings(settings(manualNotch: true), for: .afsk1200).first)
        XCTAssertEqual(fm.severity, .degrading)
        XCTAssertEqual(fm.correction, .manualNotchOff)
        XCTAssertTrue(fm.fix.contains("1200 or 2200"), fm.fix)
        var hf = settings(manualNotch: true)
        hf.mode = .usb
        let ssb = try XCTUnwrap(RigReceiveAudit.findings(hf, for: .afsk300).first { $0.correction == .manualNotchOff })
        XCTAssertTrue(ssb.fix.contains("1600 or 1800"), ssb.fix)
    }

    func testEveryReceiveMutingToneSettingIsBlocking() {
        let muting: [RigReceiveAudit.ToneSquelchFunction] = [.tsql, .dtcs, .toneTransmitDTCSReceive,
                                                             .dtcsTransmitTSQLReceive, .toneTransmitTSQLReceive]
        for tone in muting {
            let f = RigReceiveAudit.findings(settings(tone: tone), for: .afsk1200)
            XCTAssertEqual(f.count, 1, tone.label)
            XCTAssertEqual(f.first?.severity, .blocking, tone.label)
            XCTAssertEqual(f.first?.correction, .toneSquelchReceiveOff, tone.label)
            XCTAssertTrue(f.first?.detail.contains(tone.label) ?? false, tone.label)
        }
    }

    /// A tone sent only on transmit is a repeater tone. It changes nothing
    /// about what the modem hears, so it is not a receive problem.
    func testATransmitOnlyToneIsNotAFinding() {
        for tone in [RigReceiveAudit.ToneSquelchFunction.off, .tone, .dtcsTransmit] {
            XCTAssertTrue(RigReceiveAudit.findings(settings(tone: tone), for: .afsk1200).isEmpty, tone.label)
        }
    }

    /// The benign defaults judge nothing, so an unread setting never invents
    /// a fault.
    func testTheDefaultsAreBenign() {
        let s = RigReceiveAudit.Settings(attenuatorDB: 0, preamp: 1, noiseBlanker: false, noiseReduction: false,
                                         rfGainPercent: 100, squelchPercent: 0, mode: .fm, filter: 1, dataMode: true)
        XCTAssertFalse(s.autoNotch)
        XCTAssertFalse(s.manualNotch)
        XCTAssertEqual(s.toneSquelch, .off)
        XCTAssertTrue(RigReceiveAudit.findings(s, for: .afsk1200).isEmpty)
    }

    func testTheNewFindingsHaveNoEmDashes() {
        let f = RigReceiveAudit.findings(settings(autoNotch: true, manualNotch: true, tone: .tsql), for: .afsk1200)
        for finding in f {
            XCTAssertFalse((finding.title + finding.detail + finding.fix).contains("\u{2014}"), finding.title)
        }
    }

    // MARK: - Every combination

    /// All eleven things the audit judges, on and off, for both modem modes:
    /// 4096 radios. Each finding appears exactly when its condition holds,
    /// at its severity, with its correction, and the list is worst first.
    func testEveryCombination() {
        struct Check {
            let title: String
            let severity: RigReceiveAudit.Severity
            let correction: RigReceiveAudit.Correction?
        }
        for modemMode in [ModemMode.afsk1200, .afsk300] {
            let wanted = modemMode.expectedRigMode
            for bits in 0..<(1 << 11) {
                func on(_ i: Int) -> Bool { bits & (1 << i) != 0 }
                let s = RigReceiveAudit.Settings(
                    attenuatorDB: on(0) ? 10 : 0,
                    preamp: on(1) ? 0 : 1,
                    noiseBlanker: on(2),
                    noiseReduction: on(3),
                    rfGainPercent: on(4) ? 60 : 100,
                    squelchPercent: on(5) ? 30 : 0,
                    mode: on(6) ? .am : wanted,
                    filter: on(7) ? 3 : 1,
                    dataMode: true,
                    autoNotch: on(8),
                    manualNotch: on(9),
                    toneSquelch: on(10) ? .tsql : .off)
                var expected: [Check] = []
                if on(0) { expected.append(Check(title: "The attenuator is on", severity: .blocking, correction: .attenuatorOff)) }
                if on(4) { expected.append(Check(title: "RF gain is backed off", severity: .blocking, correction: .rfGainFull)) }
                if on(5) { expected.append(Check(title: "Squelch is not open", severity: .blocking, correction: .squelchOpen)) }
                if on(6) { expected.append(Check(title: "The radio is in the wrong mode", severity: .blocking, correction: nil)) }
                if on(7) { expected.append(Check(title: "A narrow filter is selected", severity: .blocking, correction: .widestFilter)) }
                if on(3) { expected.append(Check(title: "Noise reduction is on", severity: .degrading, correction: .noiseReductionOff)) }
                if on(2) { expected.append(Check(title: "The noise blanker is on", severity: .degrading, correction: .noiseBlankerOff)) }
                if on(8) { expected.append(Check(title: "The auto notch is on", severity: .blocking, correction: .autoNotchOff)) }
                if on(9) { expected.append(Check(title: "The manual notch is on", severity: .degrading, correction: .manualNotchOff)) }
                if on(10) { expected.append(Check(title: "Tone squelch is on", severity: .blocking, correction: .toneSquelchReceiveOff)) }
                if on(1) { expected.append(Check(title: "The preamp is off", severity: .suggestion, correction: nil)) }

                let found = RigReceiveAudit.findings(s, for: modemMode)
                let label = "\(modemMode) bits \(String(bits, radix: 2))"
                XCTAssertEqual(Set(found.map(\.title)), Set(expected.map(\.title)), label)
                XCTAssertEqual(found.count, expected.count, label)
                for check in expected {
                    let f = found.first { $0.title == check.title }
                    XCTAssertEqual(f?.severity, check.severity, "\(label): \(check.title)")
                    XCTAssertEqual(f?.correction, check.correction, "\(label): \(check.title)")
                }
                XCTAssertEqual(found.map(\.severity), found.map(\.severity).sorted(), "\(label): worst first")
                if expected.isEmpty { XCTAssertTrue(found.isEmpty, label) }
            }
        }
    }

    // MARK: - The drift watch

    private func finding(_ title: String) -> RigReceiveAudit.Finding {
        .init(title: title, detail: "", fix: "", severity: .blocking, correction: .autoNotchOff)
    }

    func testTheFirstAuditIsTheBaselineNotAChange() {
        var watch = RigReceiveAudit.DriftWatch()
        XCTAssertEqual(watch.observe([finding("The attenuator is on")]), [])
        XCTAssertEqual(watch.pending, [], "how the radio was at connect is not drift")
    }

    func testANewFindingSurfacesOnce() {
        var watch = RigReceiveAudit.DriftWatch()
        _ = watch.observe([])
        let notch = finding("The auto notch is on")
        XCTAssertEqual(watch.observe([notch]), [notch], "announced when it appears")
        XCTAssertEqual(watch.observe([notch]), [], "and not again while it stands")
        XCTAssertEqual(watch.observe([notch]), [])
        XCTAssertEqual(watch.pending, [notch], "still offered for fixing")
    }

    func testAFindingPutRightByHandIsNoLongerOffered() {
        var watch = RigReceiveAudit.DriftWatch()
        _ = watch.observe([])
        _ = watch.observe([finding("The auto notch is on")])
        _ = watch.observe([])
        XCTAssertEqual(watch.pending, [])
    }

    func testAFixedFindingIsResolvedAndCanSurfaceAgain() {
        var watch = RigReceiveAudit.DriftWatch()
        _ = watch.observe([])
        let notch = finding("The auto notch is on")
        _ = watch.observe([notch])
        watch.resolve([notch.title])
        XCTAssertEqual(watch.pending, [])
        XCTAssertEqual(watch.observe([]), [], "fixed, and the radio agrees")
        XCTAssertEqual(watch.observe([notch]), [notch], "turned on again later: a new change")
    }

    func testResolvingBeforeTheNextAuditStillAnnouncesARepeat() {
        var watch = RigReceiveAudit.DriftWatch()
        _ = watch.observe([])
        let notch = finding("The auto notch is on")
        _ = watch.observe([notch])
        watch.resolve([notch.title])
        // The operator turns it back on before the next audit ran.
        XCTAssertEqual(watch.observe([notch]), [notch])
    }

    func testSeveralChangesAccumulateInOrder() {
        var watch = RigReceiveAudit.DriftWatch()
        _ = watch.observe([])
        let a = finding("The auto notch is on"), b = finding("Noise reduction is on")
        _ = watch.observe([a])
        _ = watch.observe([a, b])
        XCTAssertEqual(watch.pending, [a, b])
    }
}
