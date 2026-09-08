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

    /// An APRS position packet places the station and grows a movement trail
    /// only when it actually moves.
    func testAnAPRSPositionPlacesTheStationAndTracksMovement() {
        func pos(_ info: String, at: TimeInterval) -> Packet {
            Packet(timestamp: Date(timeIntervalSince1970: at),
                   from: AX25Address(call: "W0OOD", ssid: 2), to: AX25Address(call: "APRS"),
                   via: [], frameType: .ui, control: 0x03, info: Data(info.utf8),
                   rawAx25: Data([0x01]), radioID: a)
        }
        var tracker = StationTracker()
        tracker.update(with: pos("!3933.48N/10447.65W#digi", at: 10))
        let placed = tracker.stations.first { $0.call == "W0OOD-2" }!
        XCTAssertEqual(placed.aprs?.symbolCode, "#")
        XCTAssertEqual(placed.aprs?.latitude ?? 0, 39.558, accuracy: 0.001)
        XCTAssertEqual(placed.track.count, 1)

        // Same position again → the trail does not grow.
        tracker.update(with: pos("!3933.48N/10447.65W#digi", at: 20))
        XCTAssertEqual(tracker.stations.first { $0.call == "W0OOD-2" }!.track.count, 1)

        // Moved → a new fix.
        tracker.update(with: pos("!3934.00N/10448.00W#digi", at: 30))
        XCTAssertEqual(tracker.stations.first { $0.call == "W0OOD-2" }!.track.count, 2)
    }

    /// A rebuild keeps the transmitted APRS fix and track — it must not drop a
    /// station back to its licence address (the modem-reconnect bug).
    func testRebuildKeepsAPRSPositionsAndTracks() {
        func pos(_ info: String, at: TimeInterval) -> Packet {
            Packet(timestamp: Date(timeIntervalSince1970: at),
                   from: AX25Address(call: "W0OOD", ssid: 2), to: AX25Address(call: "APRS"),
                   via: [], frameType: .ui, control: 0x03, info: Data(info.utf8),
                   rawAx25: Data([0x01]), radioID: a)
        }
        // Two positions a beacon apart, plus a plain non-position frame.
        let packets = [
            pos("!3933.48N/10447.65W#one", at: 10),
            pos("!3934.00N/10448.00W#two", at: 20),
        ]

        var live = StationTracker()
        for p in packets { live.update(with: p) }

        var rebuilt = StationTracker()
        rebuilt.rebuild(from: packets)

        let liveStation = live.stations.first { $0.call == "W0OOD-2" }!
        let rebuiltStation = rebuilt.stations.first { $0.call == "W0OOD-2" }!
        XCTAssertNotNil(rebuiltStation.aprs, "rebuild must keep the transmitted fix")
        XCTAssertEqual(rebuiltStation.aprs, liveStation.aprs, "rebuild agrees with live tracking")
        XCTAssertEqual(rebuiltStation.track.count, liveStation.track.count)
        XCTAssertEqual(rebuiltStation.track.count, 2, "the movement track survives a rebuild")
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
