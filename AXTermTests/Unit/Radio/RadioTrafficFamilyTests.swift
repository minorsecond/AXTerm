import XCTest
@testable import AXTerm

/// Classifying a radio by what it has actually heard, and deciding which
/// radio's row each family's map layers belong under.
final class RadioTrafficFamilyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private let aprsRadio = RadioID()
    private let packetRadio = RadioID()

    private func station(_ call: String,
                         on radio: RadioID,
                         aprsFrames: Int = 0,
                         sessionFrames: Int = 0) -> Station {
        var station = Station(call: call, lastHeard: now, heardCount: 1)
        station.perRadio[radio] = Station.RadioObservation(
            lastHeard: now, heardCount: max(1, aprsFrames + sessionFrames), lastVia: [],
            aprsFrames: aprsFrames, sessionFrames: sessionFrames)
        return station
    }

    // MARK: - What the frames prove

    /// A plain UI frame proves nothing: APRS and a NET/ROM NODES broadcast
    /// both ride in one, so counting UI as either would misfile every radio.
    func testUIFramesAreNotEvidenceEitherWay() {
        XCTAssertFalse(RadioTrafficClassifier.isSessionEvidence(.ui))
        XCTAssertFalse(RadioTrafficClassifier.isSessionEvidence(.unknown))
    }

    func testSessionControlFramesAreAX25Evidence() {
        XCTAssertTrue(RadioTrafficClassifier.isSessionEvidence(.i))
        XCTAssertTrue(RadioTrafficClassifier.isSessionEvidence(.s))
        XCTAssertTrue(RadioTrafficClassifier.isSessionEvidence(.u))
    }

    func testAPRSPayloadIsClassifiedAsAPRSAndNotAsASession() {
        let beacon = Packet(
            timestamp: now, from: AX25Address(call: "N0WX", ssid: 1),
            to: AX25Address(call: "APRS"), frameType: .ui, control: 0x03, pid: 0xF0,
            info: Data("!3959.13N/10515.42W_220/004g009t047".utf8))
        let evidence = StationTracker.trafficEvidence(beacon)
        XCTAssertTrue(evidence.aprs)
        XCTAssertFalse(evidence.session)
    }

    func testSABMIsClassifiedAsASessionAndNotAsAPRS() {
        let sabm = Packet(
            timestamp: now, from: AX25Address(call: "K0EPI", ssid: 7),
            to: AX25Address(call: "BPQTST", ssid: 7), frameType: .u, control: 0x3F)
        let evidence = StationTracker.trafficEvidence(sabm)
        XCTAssertFalse(evidence.aprs)
        XCTAssertTrue(evidence.session)
    }

    // MARK: - Classifying radios

    func testEachRadioIsClassifiedByItsOwnTraffic() {
        let families = RadioTrafficClassifier.families(from: [
            station("N0WX-1", on: aprsRadio, aprsFrames: 12),
            station("BPQTST-7", on: packetRadio, sessionFrames: 8),
        ])
        XCTAssertEqual(families[aprsRadio], [.aprs])
        XCTAssertEqual(families[packetRadio], [.ax25])
    }

    /// A radio that has heard nothing classifiable is absent, not empty — the
    /// caller has to be able to tell "not known yet" from "neither", because
    /// hiding a control for the second reason is how a map goes blank with no
    /// way to bring it back.
    func testARadioWithNoClassifiableTrafficIsAbsent() {
        let families = RadioTrafficClassifier.families(from: [
            station("NOCALL", on: aprsRadio),
        ])
        XCTAssertNil(families[aprsRadio])
    }

    func testAMixedChannelCarriesBoth() {
        let families = RadioTrafficClassifier.families(from: [
            station("N0WX-1", on: aprsRadio, aprsFrames: 3),
            station("BPQ-7", on: aprsRadio, sessionFrames: 4),
        ])
        XCTAssertEqual(families[aprsRadio], [.aprs, .ax25])
    }

    // MARK: - Where the layers go

    func testAFamilyCarriedByExactlyOneRadioIsFiledUnderIt() {
        let families: [RadioID: Set<RadioTrafficFamily>] = [
            aprsRadio: [.aprs], packetRadio: [.ax25],
        ]
        let plan = MapLayerPlacement.plan(families: families,
                                          radios: [aprsRadio, packetRadio])
        XCTAssertEqual(plan.perRadio[aprsRadio], [.aprs])
        XCTAssertEqual(plan.perRadio[packetRadio], [.ax25])
        XCTAssertTrue(plan.orphans.isEmpty)
        XCTAssertTrue(plan.isGrouped)
    }

    /// One switch is one setting, so it must appear once. Two radios carrying
    /// APRS would otherwise each show a "Transmitted Positions" switch bound
    /// to the same key, reading as two independent settings.
    func testAFamilyCarriedByTwoRadiosFallsBackToTheSharedSection() {
        let both: [RadioID: Set<RadioTrafficFamily>] = [
            aprsRadio: [.aprs], packetRadio: [.aprs, .ax25],
        ]
        let plan = MapLayerPlacement.plan(families: both, radios: [aprsRadio, packetRadio])
        XCTAssertNil(plan.perRadio[aprsRadio]?.contains(.aprs))
        XCTAssertTrue(plan.orphans.contains(.aprs))
        XCTAssertEqual(plan.perRadio[packetRadio], [.ax25])
    }

    func testNothingHeardYetLeavesEveryLayerInTheSharedSection() {
        let plan = MapLayerPlacement.plan(families: [:], radios: [aprsRadio, packetRadio])
        XCTAssertFalse(plan.isGrouped)
        XCTAssertEqual(plan.orphans, Set(RadioTrafficFamily.allCases))
    }

    /// A hidden radio still hosts its own layers. Relocating them to the
    /// bottom of the sidebar the moment its switch went off is what made the
    /// grouping look broken — the row is disabled instead, which says the
    /// same thing without moving anything.
    func testAHiddenRadioStillHostsItsLayers() {
        let families: [RadioID: Set<RadioTrafficFamily>] = [
            aprsRadio: [.aprs], packetRadio: [.ax25],
        ]
        let plan = MapLayerPlacement.plan(families: families,
                                          radios: [aprsRadio, packetRadio])
        XCTAssertEqual(plan.perRadio[aprsRadio], [.aprs])
        XCTAssertEqual(plan.perRadio[packetRadio], [.ax25])
        XCTAssertTrue(plan.orphans.isEmpty)
    }

    // MARK: - Scoping the layer rows

    func testScopeDecidesWhichRowsAreDrawn() {
        XCTAssertTrue(MapLayerScope.everything.includes(.aprs))
        XCTAssertTrue(MapLayerScope.everything.includes(nil))

        let aprsOnly = MapLayerScope.families([.aprs])
        XCTAssertTrue(aprsOnly.includes(.aprs))
        XCTAssertFalse(aprsOnly.includes(.ax25))
        XCTAssertFalse(aprsOnly.includes(nil),
                       "layers belonging to no family stay in the shared section")

        let shared = MapLayerScope.shared([.ax25])
        XCTAssertTrue(shared.includes(nil))
        XCTAssertTrue(shared.includes(.ax25), "an orphaned family falls back here")
        XCTAssertFalse(shared.includes(.aprs))
    }

    // MARK: - What is NOT APRS evidence

    /// The bug this guards, reported from the field: a packet-only radio was
    /// badged "APRS · AX.25". APRS only ever rides in a UI frame with PID
    /// 0xF0, and an I-frame carrying session text was being counted.
    func testSessionDataIsNeverAPRSEvidenceEvenWhenItLooksLikeIt() {
        let iFrame = Packet(
            timestamp: now, from: AX25Address(call: "KB5YZB", ssid: 7),
            to: AX25Address(call: "K0EPI", ssid: 7), frameType: .i, control: 0x00, pid: 0xF0,
            info: Data(":K0EPI-7  :hello from the BBS".utf8))
        let evidence = StationTracker.trafficEvidence(iFrame)
        XCTAssertFalse(evidence.aprs, "connected-mode data is not APRS")
        XCTAssertTrue(evidence.session)
    }

    /// `?` is the universal help command at a node prompt, and the APRS
    /// message parser accepts any text starting with it as a general query.
    /// Every operator asking a BBS for help was voting the channel APRS.
    func testABareQuestionMarkIsNotAPRSEvidence() {
        let help = Packet(
            timestamp: now, from: AX25Address(call: "N0CALL"),
            to: AX25Address(call: "BBS"), frameType: .ui, control: 0x03, pid: 0xF0,
            info: Data("?".utf8))
        XCTAssertFalse(StationTracker.trafficEvidence(help).aprs)
    }

    /// NET/ROM rides in a UI frame too, at PID 0xCF, and must not be mistaken
    /// for APRS by the PID test alone.
    func testNetRomBroadcastIsNotAPRSEvidence() {
        let nodes = Packet(
            timestamp: now, from: AX25Address(call: "DRLNOD"),
            to: AX25Address(call: "NODES"), frameType: .ui, control: 0x03, pid: 0xCF,
            info: Data([0xFF] + Array("NODES".utf8)))
        XCTAssertFalse(StationTracker.trafficEvidence(nodes).aprs)
    }

    /// A plain UI ID beacon parses as nothing and proves nothing either way.
    func testAPlainIDBeaconIsNeitherKind() {
        let id = Packet(
            timestamp: now, from: AX25Address(call: "KB5YZB", ssid: 7),
            to: AX25Address(call: "ID"), frameType: .ui, control: 0x03, pid: 0xF0,
            info: Data("KB5YZB/R YZBBPQ/D KB5YZB-1/B".utf8))
        let evidence = StationTracker.trafficEvidence(id)
        XCTAssertFalse(evidence.aprs)
        XCTAssertFalse(evidence.session)
    }

    /// What *does* count: a real APRS payload in a UI frame at PID 0xF0.
    func testRealAPRSPayloadsInUIFramesCount() {
        func evidence(_ info: String) -> Bool {
            StationTracker.trafficEvidence(Packet(
                timestamp: now, from: AX25Address(call: "N0WX", ssid: 1),
                to: AX25Address(call: "APRS"), frameType: .ui, control: 0x03, pid: 0xF0,
                info: Data(info.utf8))).aprs
        }
        XCTAssertTrue(evidence("!3959.13N/10515.42W_220/004g009t047"), "weather beacon")
        XCTAssertTrue(evidence("!3851.33N/10452.70Wj001/000"), "position")
        XCTAssertTrue(evidence(";WILDFIRE *092345z3959.13N/10515.42W:East ridge"), "object")
        XCTAssertTrue(evidence(":K0EPI-7  :are you there{1"), "addressed message")
    }
}
