import XCTest
@testable import AXTerm

/// One station, several receivers.
final class StationTrackerRadioTests: XCTestCase {

    private let a = RadioID(rawValue: "a")
    private let b = RadioID(rawValue: "b")

    private func packet(from: String, at: TimeInterval, radio: RadioID?, via: [AX25Address] = []) -> Packet {
        Packet(timestamp: Date(timeIntervalSince1970: at),
               from: AX25Address(call: from), to: AX25Address(call: "CQ"), via: via,
               frameType: .ui, control: 0x03, info: Data([0x41]), rawAx25: Data([0x01]),
               radioID: radio)
    }

    func testEachRadiosHearingIsRecordedAndTheStationCountedOnce() {
        var tracker = StationTracker()
        tracker.update(with: packet(from: "K0NTS", at: 10, radio: a))
        // The same transmission, heard by the other radio: a fold, not a packet.
        tracker.noteHeard("K0NTS", on: b, at: Date(timeIntervalSince1970: 10.3), via: [])
        tracker.update(with: packet(from: "K0NTS", at: 20, radio: a))

        let station = tracker.stations.first { $0.call == "K0NTS" }!
        XCTAssertEqual(station.heardCount, 2, "two transmissions, however many receivers")
        XCTAssertEqual(station.perRadio[a]?.heardCount, 2)
        XCTAssertEqual(station.perRadio[b]?.heardCount, 1)
        XCTAssertEqual(station.heardOn, [a, b], "most recently heard first")
    }

    /// Frames from before radios existed belong to the primary.
    func testAPacketWithNoRadioIsHeardOnThePrimary() {
        var tracker = StationTracker()
        tracker.update(with: packet(from: "K0NTS", at: 10, radio: nil))
        XCTAssertEqual(tracker.stations.first?.heardOn, [.primary])
    }

    /// A rebuild from the log reaches the same answer as live tracking, and
    /// leaves our own echoes out of it.
    func testRebuildAgreesWithLiveTrackingAndSkipsOwnEchoes() {
        var live = StationTracker()
        let packets = [
            packet(from: "K0NTS", at: 10, radio: a),
            packet(from: "K0NTS", at: 20, radio: b),
            packet(from: "W0ARP", at: 30, radio: b),
        ]
        for p in packets { live.update(with: p) }

        var rebuilt = StationTracker()
        let echo = Packet(timestamp: Date(timeIntervalSince1970: 40),
                          from: AX25Address(call: "TEST", ssid: 7), to: AX25Address(call: "CQ"),
                          frameType: .ui, control: 0x03, rawAx25: Data([0x02]),
                          radioID: b, isOwnEcho: true)
        rebuilt.rebuild(from: packets + [echo])

        XCTAssertEqual(rebuilt.stations.map(\.call).sorted(), ["K0NTS", "W0ARP"])
        XCTAssertEqual(rebuilt.stations.first { $0.call == "K0NTS" }?.perRadio,
                       live.stations.first { $0.call == "K0NTS" }?.perRadio)
        XCTAssertEqual(rebuilt.stations.first { $0.call == "K0NTS" }?.heardOn, [b, a])
    }

    /// A fold for a station the tracker has never counted is ignored: the
    /// first hearing always arrives as a packet.
    func testAFoldForAnUnknownStationIsIgnored() {
        var tracker = StationTracker()
        tracker.noteHeard("NOBODY", on: a, at: Date(), via: [])
        XCTAssertTrue(tracker.stations.isEmpty)
    }
}
