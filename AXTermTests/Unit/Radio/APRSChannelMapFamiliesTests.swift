import XCTest
@testable import AXTerm

/// A radio marked as on an APRS channel draws APRS on the map and nothing else.
///
/// The operator's one radio is a TNC4 on 144.390, marked "on an APRS channel".
/// The map still grew a packet coverage ring beside the APRS one, both reading
/// "Hearing ~23 mi". Two things put it there: a single corrupt frame decoded
/// as an I frame (source `V},'-11`) counted as connected-mode evidence and
/// filed the radio under AX.25 as well as APRS, and nothing stopped an APRS
/// channel carrying AX.25 in the first place. Both are covered here.
final class APRSChannelMapFamiliesTests: XCTestCase {

    private let tnc4 = RadioID(rawValue: "tnc4")
    private let direwolf = RadioID(rawValue: "direwolf")
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - The rule

    func testAnAPRSChannelRadioCarriesOnlyAPRS() {
        let families = RadioTrafficClassifier.mapFamilies(
            heard: [tnc4: [.aprs, .ax25]], aprsChannels: [tnc4])
        XCTAssertEqual(families[tnc4], [.aprs])
    }

    func testOtherRadiosKeepWhatTheyHeard() {
        let families = RadioTrafficClassifier.mapFamilies(
            heard: [tnc4: [.aprs, .ax25], direwolf: [.aprs, .ax25]], aprsChannels: [tnc4])
        XCTAssertEqual(families[direwolf], [.aprs, .ax25],
                       "a packet radio on a mixed channel is not the operator's APRS radio")
    }

    /// The operator has already said what the channel is; waiting for a
    /// beacon before believing it would briefly file the layers elsewhere.
    func testAnAPRSChannelRadioIsAPRSBeforeAnythingIsHeard() {
        let families = RadioTrafficClassifier.mapFamilies(heard: [:], aprsChannels: [tnc4])
        XCTAssertEqual(families[tnc4], [.aprs])
    }

    func testNoAPRSChannelsLeavesTheEvidenceAlone() {
        let heard: [RadioID: Set<RadioTrafficFamily>] = [direwolf: [.ax25]]
        XCTAssertEqual(RadioTrafficClassifier.mapFamilies(heard: heard, aprsChannels: []), heard)
    }

    // MARK: - What that does to the coverage evidence

    /// With the radio held to APRS the packet side has no radios at all, so
    /// there is nothing to build a second receive ring from.
    func testAnAPRSChannelRadioFeedsNoPacketEvidence() {
        var evidence = CoverageEvidence()
        evidence.absorb(beacon(from: "K0PWO", radio: tnc4), isOurs: false)

        let heard = RadioTrafficClassifier.families(from: [
            station("K0PWO", aprsFrames: 30, sessionFrames: 0),
            station("V},'-11", aprsFrames: 0, sessionFrames: 1),
        ])
        let before = MapCoverageEvidence(evidence, families: heard)
        let after = MapCoverageEvidence(
            evidence,
            families: RadioTrafficClassifier.mapFamilies(heard: heard, aprsChannels: [tnc4]))

        XCTAssertEqual(before.heardDirectAX25, before.heardDirectAPRS,
                       "the bug: one radio in both families hands both rings the same stations")
        XCTAssertEqual(Set(after.heardDirectAPRS.keys), ["K0PWO"])
        XCTAssertTrue(after.heardDirectAX25.isEmpty)
    }

    /// The station-list side: stations heard on the APRS-channel radio are
    /// governed by the APRS layers even when the radio has heard session
    /// frames too.
    func testStationsOnAnAPRSChannelRadioAreOnAnAPRSChannel() {
        let stations = [station("KC5W", aprsFrames: 0, sessionFrames: 4)]
        let heard = RadioTrafficClassifier.families(from: stations)
        XCTAssertTrue(MapEntryVisibility.callsOnAPRSChannels(
            stations: stations, families: heard).isEmpty,
            "fixture: on evidence alone this radio is a packet channel")

        let onAPRS = MapEntryVisibility.callsOnAPRSChannels(
            stations: stations,
            families: RadioTrafficClassifier.mapFamilies(heard: heard, aprsChannels: [tnc4]))
        XCTAssertEqual(onAPRS, ["KC5W"])
    }

    // MARK: - The corrupt frame

    /// The frame from the test database on 2026-09-30 at 10:22:58, as the
    /// decoder handed it over. Its addresses cannot belong to any station.
    func testAFrameWithImpossibleAddressesIsNotSessionEvidence() {
        let garbage = Packet(
            timestamp: at, from: AX25Address(call: "V},'", ssid: 11),
            to: AX25Address(call: ";Q,C*B", ssid: 6),
            via: [AX25Address(call: "D#=|M", ssid: 3)],
            frameType: .i, control: 0x18, pid: 0, radioID: tnc4)
        XCTAssertFalse(StationTracker.trafficEvidence(garbage).session)
    }

    func testARealIFrameIsStillSessionEvidence() {
        let frame = Packet(
            timestamp: at, from: AX25Address(call: "KB5YZB", ssid: 7),
            to: AX25Address(call: "K0EPI", ssid: 7),
            frameType: .i, control: 0x00, pid: 0xF0, info: Data("hello\r".utf8))
        XCTAssertTrue(StationTracker.trafficEvidence(frame).session)
    }

    func testWellFormedAddressRules() {
        XCTAssertTrue(RadioTrafficClassifier.hasWellFormedAddresses(from: "K0EPI", to: "BPQTST"))
        XCTAssertTrue(RadioTrafficClassifier.hasWellFormedAddresses(from: "3DA0XY", to: "NODES"))
        XCTAssertFalse(RadioTrafficClassifier.hasWellFormedAddresses(from: "K0EPI", to: nil))
        XCTAssertFalse(RadioTrafficClassifier.hasWellFormedAddresses(from: "", to: "K0EPI"))
        XCTAssertFalse(RadioTrafficClassifier.hasWellFormedAddresses(from: "K0EPIXX", to: "K0EPI"),
                       "seven characters do not fit an AX.25 address")
        XCTAssertFalse(RadioTrafficClassifier.hasWellFormedAddresses(from: "k0epi", to: "K0EPI"),
                       "addresses are upper case on the air")
    }

    // MARK: - Helpers

    private func station(_ call: String, aprsFrames: Int, sessionFrames: Int) -> Station {
        var station = Station(call: call, lastHeard: at, heardCount: aprsFrames + sessionFrames)
        station.perRadio[tnc4] = Station.RadioObservation(
            lastHeard: at, heardCount: max(1, aprsFrames + sessionFrames), lastVia: [],
            aprsFrames: aprsFrames, sessionFrames: sessionFrames)
        return station
    }

    private func beacon(from call: String, radio: RadioID) -> Packet {
        Packet(timestamp: at, from: AX25Address(call: call),
               to: AX25Address(call: "APGRWO"),
               via: [AX25Address(call: "WIDE1", ssid: 1), AX25Address(call: "WIDE2", ssid: 1)],
               frameType: .ui, control: 0x03, pid: 0xF0,
               info: Data("!/:Z334&33-  C".utf8), radioID: radio)
    }
}
