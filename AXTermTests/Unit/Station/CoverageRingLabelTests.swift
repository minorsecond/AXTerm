import XCTest
@testable import AXTerm

/// Two rings built from the same stations are one ring, and rings from the
/// two families say which they are.
///
/// One APRS radio that had also been filed under AX.25 drew two identical
/// teal circles with two chips reading "Hearing ~23 mi", and a legend listing
/// "Typical hearing (hearing)" twice.
final class CoverageRingLabelTests: XCTestCase {

    private func hearing(_ family: RadioTrafficFamily?, reachKm: Double = 36.6,
                         farthest: String = "K0PWO") -> CoverageEstimate.Ring {
        CoverageEstimate.Ring(typicalKm: 4.3, reachKm: reachKm, stationCount: 6,
                              farthestCallsign: farthest, evidence: .heardDirect,
                              family: family)
    }

    private let repeated = CoverageEstimate.Ring(
        typicalKm: 25, reachKm: 90, stationCount: 9,
        farthestCallsign: "WA6IFI-6", evidence: .digipeated, family: .aprs)

    private let answered = CoverageEstimate.Ring(
        typicalKm: 10, reachKm: 30, stationCount: 4,
        farthestCallsign: "K0NTS-7", evidence: .answered, family: .ax25)

    // MARK: - Dedupe

    func testIdenticalReceiveRingsBecomeOne() {
        let rings = CoverageRingSelection.rings(
            answered: nil, showsAnswered: true, digipeated: nil, showsDigipeated: true,
            received: [hearing(.ax25), hearing(.aprs)], showsReceived: true)
        XCTAssertEqual(rings.count, 1, "the same stations measured twice are one measurement")
        XCTAssertNil(rings.first?.family, "the survivor stands for both families")
    }

    func testDifferentReceiveRingsBothStay() {
        let rings = CoverageRingSelection.rings(
            answered: nil, showsAnswered: true, digipeated: nil, showsDigipeated: true,
            received: [hearing(.ax25, reachKm: 12, farthest: "KB5YZB-7"), hearing(.aprs)],
            showsReceived: true)
        XCTAssertEqual(rings.map(\.family), [.ax25, .aprs])
    }

    /// A transmit ring and a receive ring can land on the same distance by
    /// chance; they are different measurements and must both be drawn.
    func testDedupeNeverMergesDifferentEvidence() {
        var coincidence = hearing(.aprs)
        coincidence.evidence = .digipeated
        XCTAssertEqual(CoverageRingSelection.deduplicated([coincidence, hearing(.aprs)]).count, 2)
    }

    // MARK: - Chip labels

    func testALoneRingIsJustCoverage() {
        XCTAssertEqual(CoverageRingSelection.chipLabel(for: hearing(.aprs),
                                                       among: [hearing(.aprs)]),
                       "Coverage")
    }

    func testOneFamilyNamesTheEvidenceOnly() {
        let rings = [repeated, hearing(.aprs)]
        XCTAssertEqual(rings.map { CoverageRingSelection.chipLabel(for: $0, among: rings) },
                       ["Repeated", "Hearing"])
    }

    func testBothFamiliesPutTheFamilyInFront() {
        let packetHearing = hearing(.ax25, reachKm: 12, farthest: "KB5YZB-7")
        let rings = [answered, repeated, packetHearing, hearing(.aprs)]
        let labels = rings.map { CoverageRingSelection.chipLabel(for: $0, among: rings) }
        XCTAssertEqual(labels, ["Packet answered", "APRS repeated",
                                "Packet hearing", "APRS hearing"])
        XCTAssertEqual(Set(labels).count, labels.count, "no two chips may read the same")
    }

    // MARK: - Legend

    func testLegendQualifiersNeverRepeatTheLegendsOwnWords() {
        let rings = [repeated, hearing(.aprs)]
        XCTAssertNil(CoverageRingSelection.legendQualifier(for: repeated, among: rings),
                     "\"Typical coverage\" already says it is the transmit ring")
        XCTAssertNil(CoverageRingSelection.legendQualifier(for: hearing(.aprs), among: rings),
                     "\"Typical hearing (hearing)\" was the bug")
    }

    func testLegendNamesFamiliesAndProofsWhenNeeded() {
        let packetHearing = hearing(.ax25, reachKm: 12, farthest: "KB5YZB-7")
        let rings = [answered, repeated, packetHearing, hearing(.aprs)]
        XCTAssertEqual(
            rings.map { CoverageRingSelection.legendQualifier(for: $0, among: rings) },
            ["Packet, answered", "APRS, repeated", "Packet", "APRS"])
    }

    func testRingIdentitiesAreUniqueForEverythingDrawnTogether() {
        let packetHearing = hearing(.ax25, reachKm: 12, farthest: "KB5YZB-7")
        let rings = [answered, repeated, packetHearing, hearing(.aprs)]
        XCTAssertEqual(Set(rings.map(\.legendID)).count, rings.count)
    }

    func testTheReceiveTooltipSaysWhichRadiosItCounted() {
        XCTAssertTrue(hearing(.aprs).summary.contains("radios carrying APRS"))
        XCTAssertTrue(hearing(.ax25).summary.contains("radios carrying packet traffic"))
        XCTAssertFalse(hearing(nil).summary.contains("radios carrying"))
    }

    /// The builders file each ring under the family its evidence belongs to.
    func testBuildersSayWhichFamilyTheyMeasured() {
        let observer = GreatCircle.Point(latitude: 39.6125, longitude: -104.7331)
        let positions = ["WA0DE-9": GreatCircle.Point(latitude: 39.3935, longitude: -104.6748)]
        let when = Date()
        XCTAssertEqual(CoverageEstimate.digipeatRing(
            repeaters: ["WA0DE-9": when], positions: positions, observer: observer)?.family,
            .aprs)
        XCTAssertEqual(CoverageEstimate.receiveRing(
            heardDirect: ["WA0DE-9": when], family: .aprs,
            positions: positions, observer: observer)?.family, .aprs)
        XCTAssertNil(CoverageEstimate.receiveRing(
            heardDirect: ["WA0DE-9": when], positions: positions, observer: observer)?.family)
    }
}
