//
//  AdaptiveBeaconEvidenceTests.swift
//  AXTermTests
//
//  The adaptive tuner may only learn from traffic that can report a loss.
//

import XCTest
@testable import AXTerm

/// A listen-only beacon link can say that a frame arrived and can never say
/// that one did not: a beacon we missed leaves no retransmission, no REJ and
/// no gap to count. Its delivery estimate therefore settles at whatever credit
/// an arrival earns rather than at anything measured, and feeding that to the
/// transmission tuner clamps a healthy radio for reasons that do not exist.
@MainActor
final class AdaptiveBeaconEvidenceTests: XCTestCase {

    private let aprsRadio = RadioID(rawValue: "aprs")
    private let packetRadio = RadioID(rawValue: "packet")

    private func link(
        _ from: String, _ to: String,
        df: Double,
        radio: RadioID,
        obs: Int = 50,
        session: Int
    ) -> LinkStatRecord {
        LinkStatRecord(fromCall: from, toCall: to, quality: 200, lastUpdated: Date(),
                       dfEstimate: df, drEstimate: df, duplicateCount: 0,
                       observationCount: obs, radioID: radio,
                       sessionEvidenceCount: session)
    }

    // MARK: - The aggregate gate

    /// The case from the field: an IC-705 on 144.390 hearing nothing but APRS.
    /// Every link parked at the UI-beacon credit of 0.4, which the tuner read
    /// as 60% loss and answered with stop-and-wait at paclen 64.
    func testABeaconOnlyRadioProducesNoAdaptiveSample() {
        let records = [
            link("WQ8M-9", "APRX29", df: 0.4, radio: aprsRadio, session: 0),
            link("AD1CT", "APGRWO", df: 0.4, radio: aprsRadio, session: 0),
            link("K5RHD-10", "APMI06", df: 0.4, radio: aprsRadio, session: 0),
        ]
        XCTAssertNil(ContentView.aggregateLinkQualityForAdaptive(records, localCallsign: "K0EPI"),
                     "beacons cannot report loss, so they must not be asked about it")
        XCTAssertTrue(ContentView.aggregateLinkQualityPerRadio(records, localCallsign: "K0EPI").isEmpty,
                      "the radio falls through to the operator's configured settings")
    }

    /// And the figure that radio used to produce, pinned so nobody restores it.
    func testTheFabricatedFigureIsWhatTheGateKeepsOut() throws {
        let records = [
            link("WQ8M-9", "APRX29", df: 0.4, radio: aprsRadio, session: 0),
            link("AD1CT", "APGRWO", df: 0.4, radio: aprsRadio, session: 0),
        ]
        // With the gate lifted, this is the 60% loss and ETX 6.25 the operator
        // was shown on a channel that was digipeating his beacons fine.
        let ungated = records.map {
            link($0.fromCall, $0.toCall, df: 0.4, radio: aprsRadio, session: 1)
        }
        let sample = try XCTUnwrap(
            ContentView.aggregateLinkQualityForAdaptive(ungated, localCallsign: "K0EPI"))
        XCTAssertEqual(sample.lossRate, 0.60, accuracy: 0.01)
        XCTAssertEqual(sample.etx, 6.25, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(sample.lossRate, 0.2,
                                    "which is past the stop-and-wait trigger")
    }

    /// A NET/ROM broadcast is a UI frame too, credited 0.8, which lands on
    /// exactly the 20% stop-and-wait threshold. Same defect, different number.
    func testNodeBroadcastsAreExcludedForTheSameReason() {
        let records = [
            link("K0NTS-7", "DRLNOD", df: 0.8, radio: packetRadio, session: 0),
            link("KB5YZB-7", "YZBBPQ", df: 0.8, radio: packetRadio, session: 0),
        ]
        XCTAssertNil(ContentView.aggregateLinkQualityForAdaptive(records, localCallsign: "K0EPI"))
    }

    func testARadioWithConnectedModeEvidenceStillProducesASample() throws {
        let records = [
            link("K0EPI", "W0ARP-1", df: 0.95, radio: packetRadio, session: 40),
        ]
        let sample = try XCTUnwrap(
            ContentView.aggregateLinkQualityForAdaptive(records, localCallsign: "K0EPI"))
        XCTAssertEqual(sample.lossRate, 0.05, accuracy: 0.02)
    }

    /// A radio doing both keeps learning from the half that can teach it.
    /// Gating on the radio rather than the evidence would have thrown this away.
    func testBeaconsDoNotDragDownARadioThatAlsoRunsSessions() throws {
        let records = [
            link("K0EPI", "W0ARP-1", df: 0.95, radio: packetRadio, session: 40),
            link("WQ8M-9", "APRX29", df: 0.4, radio: packetRadio, session: 0),
            link("AD1CT", "APGRWO", df: 0.4, radio: packetRadio, session: 0),
        ]
        let byRadio = ContentView.aggregateLinkQualityPerRadio(records, localCallsign: nil)
        let sample = try XCTUnwrap(byRadio[packetRadio])
        XCTAssertEqual(sample.lossRate, 0.05, accuracy: 0.02,
                       "the session link answers; the beacons are not consulted")
    }

    // MARK: - Where the count comes from

    private func makePacket(from: String, to: String, frameType: FrameType,
                            control: UInt8, timestamp: Date) -> Packet {
        let info = "TEST".data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: frameType,
            control: control,
            controlByte1: nil,
            info: info,
            rawAx25: info,
            infoText: "TEST"
        )
    }

    func testAUIBeaconContributesNoSessionEvidence() {
        var estimator = LinkQualityEstimator()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<20 {
            let packet = makePacket(from: "WQ8M-9", to: "APRX29", frameType: .ui,
                                    control: 0x03, timestamp: t.addingTimeInterval(Double(i) * 60))
            estimator.observePacket(packet, timestamp: t.addingTimeInterval(Double(i) * 60))
        }
        let stats = estimator.linkStats(from: "WQ8M-9", to: "APRX29")
        XCTAssertGreaterThan(stats.observationCount, 0, "the beacons were heard")
        XCTAssertEqual(stats.sessionEvidenceCount, 0, "and none of them can report a loss")
    }

    func testAnIFrameContributesSessionEvidence() {
        var estimator = LinkQualityEstimator()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<10 {
            let packet = makePacket(from: "K0EPI", to: "W0ARP-1", frameType: .i,
                                    control: UInt8((i % 8) << 1), timestamp: t.addingTimeInterval(Double(i)))
            estimator.observePacket(packet, timestamp: t.addingTimeInterval(Double(i)))
        }
        let stats = estimator.linkStats(from: "K0EPI", to: "W0ARP-1")
        XCTAssertGreaterThan(stats.sessionEvidenceCount, 0)
    }

    /// The mechanism itself, stated once: a beacon-only link converges on the
    /// credit an arrival earns, not on a measurement. Hearing more of them
    /// moves the estimate toward 0.4 rather than toward health.
    func testABeaconOnlyLinkConvergesOnTheEvidenceWeightRatherThanAMeasurement() throws {
        var estimator = LinkQualityEstimator()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<200 {
            let when = t.addingTimeInterval(Double(i) * 600)
            estimator.observePacket(
                makePacket(from: "WQ8M-9", to: "APRX29", frameType: .ui,
                           control: 0x03, timestamp: when),
                timestamp: when)
        }
        let df = try XCTUnwrap(estimator.linkStats(from: "WQ8M-9", to: "APRX29").dfEstimate)
        XCTAssertEqual(df, 0.4, accuracy: 0.05,
                       "every beacon heard pulls the estimate toward the 0.4 credit")
    }

    /// The count has to survive a restart, or the first launch after one would
    /// silently exclude every link the app had already qualified.
    func testSessionEvidenceSurvivesExportAndImport() throws {
        var estimator = LinkQualityEstimator()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<10 {
            let when = t.addingTimeInterval(Double(i))
            estimator.observePacket(
                makePacket(from: "K0EPI", to: "W0ARP-1", frameType: .i,
                           control: UInt8((i % 8) << 1), timestamp: when),
                timestamp: when)
        }
        let exported = estimator.exportLinkStats()
        let before = try XCTUnwrap(exported.first { $0.fromCall == "K0EPI" })
        XCTAssertGreaterThan(before.sessionEvidenceCount, 0)

        var restored = LinkQualityEstimator()
        restored.importLinkStats(exported)
        let after = try XCTUnwrap(
            restored.exportLinkStats().first { $0.fromCall == "K0EPI" })
        XCTAssertEqual(after.sessionEvidenceCount, before.sessionEvidenceCount)
    }
}

/// Which channel the toolbar shows when the operator has picked nothing.
///
/// A station with an APRS radio and an AX.25 radio has one radio that can
/// earn a figure and one that never will. Pinning the display to the primary
/// meant that if the primary was the APRS one, the toolbar showed configured
/// defaults with every measured field blank while the other radio was
/// learning normally.
final class AdaptiveDefaultChannelTests: XCTestCase {

    private let aprs = RadioID(rawValue: "aprs")
    private let packet = RadioID(rawValue: "packet")

    func testThePrimaryWinsWhenItHasAFigure() {
        XCTAssertEqual(
            SessionCoordinator.defaultChannelRadio(among: [aprs, packet], primary: packet),
            packet)
    }

    /// The case from the field: the primary cannot learn, so the display
    /// shows the radio that can rather than falling back to the baseline.
    func testARadioThatCanLearnIsShownWhenThePrimaryCannot() {
        XCTAssertEqual(
            SessionCoordinator.defaultChannelRadio(among: [packet], primary: aprs),
            packet)
    }

    func testNothingToShowStaysNothing() {
        XCTAssertNil(SessionCoordinator.defaultChannelRadio(among: [], primary: aprs))
    }

    /// Fixed order, so two eligible channels cannot make the figure flip
    /// between them on successive polls.
    func testTheChoiceIsStableAcrossOrderings() {
        let a = SessionCoordinator.defaultChannelRadio(among: [aprs, packet], primary: .primary)
        let b = SessionCoordinator.defaultChannelRadio(among: [packet, aprs], primary: .primary)
        XCTAssertEqual(a, b)
    }
}

/// Naming the radios the tuner cannot learn from.
///
/// A radio with no adaptive figure is otherwise indistinguishable from a
/// broken one, and an APRS radio will never have a figure however long the
/// operator waits. The notice makes a positive claim about a radio, so it
/// needs positive evidence: the frames that radio has decoded.
@MainActor
final class APRSOnlyRadioNoticeTests: XCTestCase {

    private let aprs = RadioID(rawValue: "aprs")
    private let packet = RadioID(rawValue: "packet")

    func testAnAPRSOnlyRadioIsNamed() {
        let families: [RadioID: Set<RadioTrafficFamily>] = [aprs: [.aprs]]
        XCTAssertEqual(ContentView.radiosCarryingOnlyAPRS(families: families), [aprs])
    }

    /// The regression that shipped: Direwolf carries two-way connected-mode
    /// traffic and was announced as hearing only beacons, because the notice
    /// was reading a link-statistics column that every migrated row returned
    /// zero for. A radio with session traffic is never named, whatever else
    /// it also carries.
    func testATwoWayAX25RadioIsNeverNamed() {
        XCTAssertTrue(
            ContentView.radiosCarryingOnlyAPRS(families: [packet: [.ax25]]).isEmpty)
        XCTAssertTrue(
            ContentView.radiosCarryingOnlyAPRS(families: [packet: [.aprs, .ax25]]).isEmpty,
            "a radio doing both can still learn from the half that teaches it")
    }

    /// Silence is a radio that has not started, which is not the same as one
    /// that cannot learn.
    func testARadioThatHasHeardNothingIsNotNamed() {
        XCTAssertTrue(ContentView.radiosCarryingOnlyAPRS(families: [:]).isEmpty)
        XCTAssertTrue(ContentView.radiosCarryingOnlyAPRS(families: [aprs: []]).isEmpty)
    }

    /// Each radio answers for itself, and the order does not wander.
    func testRadiosAreReportedIndependentlyAndInAFixedOrder() {
        let families: [RadioID: Set<RadioTrafficFamily>] = [aprs: [.aprs], packet: [.ax25]]
        XCTAssertEqual(ContentView.radiosCarryingOnlyAPRS(families: families), [aprs])
    }
}
