import XCTest
@testable import AXTerm

/// Evidence for the two directions of coverage.
///
/// The distinction these tests defend is that a digipeated frame proves the
/// digipeater's link and nothing about the station that originated it. Losing
/// that turns "who I can hear" into "who anybody can hear", which on a
/// network built out of hilltop repeaters is most of the continent.
final class CoverageEvidenceTests: XCTestCase {

    private let handheld = RadioID(rawValue: "705")
    private let packetRadio = RadioID.primary
    private let at = Date(timeIntervalSince1970: 10_000)

    // MARK: - Transmit

    func testADigipeaterThatRepeatedOurFrameProvesItDecodedUs() {
        var evidence = CoverageEvidence()
        evidence.absorb(
            ourBeacon(via: [("AD1CT", true), ("WIDE1", true), ("WIDE2-1", false)]),
            isOurs: true)

        XCTAssertEqual(
            Set(evidence.repeatedUs(on: [handheld]).keys), ["AD1CT", "WIDE1"],
            "only the hops marked repeated actually put the frame back on the air")
    }

    func testAHopThatNeverRepeatedIsNotEvidence() {
        var evidence = CoverageEvidence()
        evidence.absorb(ourBeacon(via: [("WIDE2-1", false)]), isOurs: true)

        XCTAssertTrue(
            evidence.repeatedUs(on: [handheld]).isEmpty,
            "a requested path entry is a request, not a reception")
    }

    // MARK: - Receive

    func testAFrameThatReachedUsDirectProvesWeDecodedTheSender() {
        var evidence = CoverageEvidence()
        evidence.absorb(theirBeacon(from: "WQ8M-9", via: []), isOurs: false)

        XCTAssertEqual(Set(evidence.heardDirect(on: [handheld]).keys), ["WQ8M-9"])
    }

    func testADigipeatedFrameSaysNothingAboutWhoSentIt() {
        var evidence = CoverageEvidence()
        evidence.absorb(
            theirBeacon(from: "KF0YKI-9", via: [("SIMLA", true), ("WIDE1", true)]),
            isOurs: false)

        XCTAssertTrue(
            evidence.heardDirect(on: [handheld]).isEmpty,
            "what reached our receiver was SIMLA's transmitter, not KF0YKI-9's")
    }

    /// The far end of a digipeated frame is not ours to claim, but the
    /// digipeater that delivered it is a station we heard direct.
    func testOurOwnTransmissionsAreNeverEvidence() {
        var evidence = CoverageEvidence()
        evidence.absorb(ourBeacon(via: [("AD1CT", true)], direction: .tx), isOurs: true)

        XCTAssertTrue(
            evidence.repeatedUs(on: [handheld]).isEmpty,
            "keying up is not proof that anybody heard it")
    }

    // MARK: - Radios

    func testEachRadioKeepsItsOwnReach() {
        var evidence = CoverageEvidence()
        evidence.absorb(theirBeacon(from: "WQ8M-9", via: [], radio: handheld), isOurs: false)
        evidence.absorb(theirBeacon(from: "K0NTS-7", via: [], radio: packetRadio), isOurs: false)

        XCTAssertEqual(Set(evidence.heardDirect(on: [handheld]).keys), ["WQ8M-9"])
        XCTAssertEqual(Set(evidence.heardDirect(on: [packetRadio]).keys), ["K0NTS-7"])
        XCTAssertEqual(
            Set(evidence.heardDirect(on: [handheld, packetRadio]).keys),
            ["WQ8M-9", "K0NTS-7"],
            "radios asked about together roll up")
    }

    func testTheLatestSightingWins() {
        var evidence = CoverageEvidence()
        evidence.absorb(theirBeacon(from: "WQ8M-9", via: [], when: at), isOurs: false)
        let later = at.addingTimeInterval(600)
        evidence.absorb(theirBeacon(from: "WQ8M-9", via: [], when: later), isOurs: false)

        XCTAssertEqual(evidence.heardDirect(on: [handheld])["WQ8M-9"], later)
    }

    // MARK: - History

    func testHistoryBuildsTheSamePictureAsLiveFrames() {
        let packets = [
            ourBeacon(via: [("AD1CT", true)]),
            theirBeacon(from: "WQ8M-9", via: []),
            theirBeacon(from: "KF0YKI-9", via: [("SIMLA", true)]),
        ]

        let evidence = CoverageEvidence.from(packets) { call in
            call.uppercased().hasPrefix("K0EPI")
        }

        XCTAssertEqual(Set(evidence.repeatedUs(on: [handheld]).keys), ["AD1CT"])
        XCTAssertEqual(Set(evidence.heardDirect(on: [handheld]).keys), ["WQ8M-9"])
    }

    // MARK: - Fixtures

    private func ourBeacon(via: [(String, Bool)],
                           direction: Packet.Direction = .rx,
                           when: Date? = nil) -> Packet {
        packet(from: "K0EPI-5", via: via, radio: handheld,
               direction: direction, when: when ?? at)
    }

    private func theirBeacon(from: String, via: [(String, Bool)],
                             radio: RadioID? = nil, when: Date? = nil) -> Packet {
        packet(from: from, via: via, radio: radio ?? handheld,
               direction: .rx, when: when ?? at)
    }

    private func packet(from: String, via: [(String, Bool)], radio: RadioID,
                        direction: Packet.Direction, when: Date) -> Packet {
        let parsed = CallsignParser.parse(from)
        return Packet(
            timestamp: when,
            from: AX25Address(call: parsed.base, ssid: parsed.ssid ?? 0),
            to: AX25Address(call: "APZAXT"),
            via: via.map { call, repeated in
                let hop = CallsignParser.parse(call)
                return AX25Address(call: hop.base, ssid: hop.ssid ?? 0, repeated: repeated)
            },
            frameType: .ui,
            control: 0x03,
            pid: 0xF0,
            info: Data([0x21]),
            rawAx25: Data([0x00]),
            radioID: radio,
            direction: direction)
    }
}

/// Seeding the store from stored history.
///
/// The bug this covers: the evidence was live-only, so a ring sat empty for
/// a whole session while the proof was already in the packet history
/// (2026-09-17, last beacon heard back 42 minutes before launch).
@MainActor
final class CoverageEvidenceStoreTests: XCTestCase {

    private let handheld = RadioID(rawValue: "705")

    func testHistoryFillsTheEvidenceThatLiveFramesWouldWaitHoursFor() {
        let store = CoverageEvidenceStore()
        store.isOurs = { $0.uppercased().hasPrefix("K0EPI") }

        store.seed([ourBeaconRepeated(by: "AD1CT"), theirDirectBeacon(from: "WQ8M-9")])

        XCTAssertEqual(Set(store.evidence.repeatedUs(on: [handheld]).keys), ["AD1CT"])
        XCTAssertEqual(Set(store.evidence.heardDirect(on: [handheld]).keys), ["WQ8M-9"])
    }

    /// History is read after launch, so the buffer can hold a live frame
    /// before it holds anything else. Latching on that would throw the
    /// history away.
    func testHistoryArrivingAfterALiveFrameIsStillPickedUp() {
        let store = CoverageEvidenceStore()
        store.isOurs = { $0.uppercased().hasPrefix("K0EPI") }

        store.seed([theirDirectBeacon(from: "WQ8M-9")])
        let history = (0..<10).map { theirDirectBeacon(from: "N0SZ-\($0)") }
            + [ourBeaconRepeated(by: "AD1CT"), theirDirectBeacon(from: "WQ8M-9")]
        store.seed(history)

        XCTAssertEqual(Set(store.evidence.repeatedUs(on: [handheld]).keys), ["AD1CT"])
        XCTAssertTrue(store.evidence.heardDirect(on: [handheld]).keys.contains("WQ8M-9"),
                      "the earlier seed's evidence is merged, not replaced")
        XCTAssertEqual(store.evidence.heardDirect(on: [handheld]).count, 11)
    }

    func testOrdinaryLiveGrowthDoesNotRescanTheWholeBuffer() {
        let store = CoverageEvidenceStore()
        store.isOurs = { $0.uppercased().hasPrefix("K0EPI") }
        let history = (0..<10).map { theirDirectBeacon(from: "N0SZ-\($0)") }

        store.seed(history)
        store.seed(history + [theirDirectBeacon(from: "NEW-1")])

        XCTAssertFalse(
            store.evidence.heardDirect(on: [handheld]).keys.contains("NEW-1"),
            "one more frame is the live subscription's job, not a rescan's")
    }

    private func ourBeaconRepeated(by digi: String) -> Packet {
        Packet(timestamp: Date(timeIntervalSince1970: 100),
               from: AX25Address(call: "K0EPI", ssid: 5),
               to: AX25Address(call: "APZAXT"),
               via: [AX25Address(call: digi, repeated: true)],
               frameType: .ui, control: 0x03, pid: 0xF0,
               info: Data([0x21]), rawAx25: Data([0x00]),
               radioID: handheld, direction: .rx)
    }

    private func theirDirectBeacon(from: String) -> Packet {
        let parsed = CallsignParser.parse(from)
        return Packet(timestamp: Date(timeIntervalSince1970: 100),
                      from: AX25Address(call: parsed.base, ssid: parsed.ssid ?? 0),
                      to: AX25Address(call: "APRS"),
                      frameType: .ui, control: 0x03, pid: 0xF0,
                      info: Data([0x21]), rawAx25: Data([0x00]),
                      radioID: handheld, direction: .rx)
    }
}
