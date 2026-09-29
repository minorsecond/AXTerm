import XCTest
@testable import AXTerm

final class AnalyticsRadioChannelTests: XCTestCase {

    private let a = RadioID(rawValue: "a")
    private let b = RadioID(rawValue: "b")
    private let c = RadioID(rawValue: "c")

    private func radio(_ id: RadioID, _ name: String, _ hz: Int?) -> AnalyticsRadioChannel.Radio {
        AnalyticsRadioChannel.Radio(id: id, name: name, frequencyHz: hz)
    }

    // MARK: - Grouping

    func testSameFrequencyRadiosRollUpIntoOneChannel() {
        let channels = AnalyticsRadioChannel.channels(
            radios: [radio(a, "IC-705", 144_390_000), radio(b, "IC-705 #2", 144_390_000)],
            hidden: [])
        XCTAssertEqual(channels.count, 1, "one frequency, one channel")
        XCTAssertEqual(channels[0].radioIDs, [a, b])
        XCTAssertEqual(channels[0].label, "144.39 MHz")
        XCTAssertEqual(channels[0].id, "freq:144390000")
    }

    func testDifferentFrequenciesStaySeparateAndOrderedByFrequency() {
        let channels = AnalyticsRadioChannel.channels(
            radios: [radio(a, "APRS", 144_390_000), radio(b, "Packet", 145_050_000)],
            hidden: [])
        XCTAssertEqual(channels.map(\.frequencyHz), [144_390_000, 145_050_000],
                       "ascending by frequency, deterministic")
        XCTAssertEqual(channels.map(\.label), ["144.39 MHz", "145.05 MHz"])
    }

    func testUnknownFrequencyRadioIsItsOwnChannelAfterKnownOnes() {
        let channels = AnalyticsRadioChannel.channels(
            radios: [radio(a, "Direwolf", nil), radio(b, "IC-705", 144_390_000)],
            hidden: [])
        XCTAssertEqual(channels.count, 2)
        // Known frequency first, unknown after.
        XCTAssertEqual(channels[0].frequencyHz, 144_390_000)
        XCTAssertNil(channels[1].frequencyHz)
        XCTAssertEqual(channels[1].label, "Direwolf")
        XCTAssertEqual(channels[1].id, "radio:a")
    }

    func testHiddenRadiosAreDropped() {
        let channels = AnalyticsRadioChannel.channels(
            radios: [radio(a, "APRS", 144_390_000), radio(b, "Packet", 145_050_000)],
            hidden: [b])
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].radioIDs, [a])
    }

    func testFrequencyLabelTrimsTrailingZeros() {
        XCTAssertEqual(AnalyticsRadioChannel.frequencyLabel(146_000_000), "146 MHz")
        XCTAssertEqual(AnalyticsRadioChannel.frequencyLabel(144_390_000), "144.39 MHz")
    }

    // MARK: - Filtering

    private func packet(radio: RadioID?) -> Packet {
        Packet(timestamp: Date(), from: AX25Address(call: "K0NTS"),
               to: AX25Address(call: "CQ"), frameType: .ui, control: 0x03,
               rawAx25: Data([0x01]), radioID: radio)
    }

    func testAllScopeDropsHiddenRadiosButKeepsTheRest() {
        let channels = AnalyticsRadioChannel.channels(
            radios: [radio(a, "APRS", 144_390_000), radio(b, "Packet", 145_050_000)],
            hidden: [b])
        let packets = [packet(radio: a), packet(radio: b), packet(radio: a)]
        let filtered = AnalyticsRadioFilter.apply(
            packets, scope: .all, channels: channels, hidden: [b])
        XCTAssertEqual(filtered.count, 2, "b is hidden, its packet is dropped")
        XCTAssertTrue(filtered.allSatisfy { $0.radioID == a })
    }

    func testChannelScopeKeepsOnlyThatChannelsRadios() {
        let channels = AnalyticsRadioChannel.channels(
            radios: [radio(a, "APRS", 144_390_000), radio(b, "Packet", 145_050_000)],
            hidden: [])
        let packets = [packet(radio: a), packet(radio: b)]
        let filtered = AnalyticsRadioFilter.apply(
            packets, scope: .channel("freq:145050000"), channels: channels, hidden: [])
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.radioID, b)
    }

    func testAPacketWithNoRadioCountsAsThePrimary() {
        // Pre-radio frames belong to the primary; a channel that is not the
        // primary's must not sweep them in.
        let channels = AnalyticsRadioChannel.channels(
            radios: [radio(.primary, "Primary", 144_390_000), radio(b, "Packet", 145_050_000)],
            hidden: [])
        let filtered = AnalyticsRadioFilter.apply(
            [packet(radio: nil)], scope: .channel("freq:144390000"),
            channels: channels, hidden: [])
        XCTAssertEqual(filtered.count, 1, "nil radio folds into the primary's channel")
    }

    func testAVanishedChannelSelectionFallsBackToAllVisible() {
        let channels = AnalyticsRadioChannel.channels(
            radios: [radio(a, "APRS", 144_390_000)], hidden: [])
        // Selection names a channel that no longer exists.
        let filtered = AnalyticsRadioFilter.apply(
            [packet(radio: a)], scope: .channel("freq:999"),
            channels: channels, hidden: [])
        XCTAssertEqual(filtered.count, 1, "unknown channel shows all visible, not nothing")
    }

    func testEmptyScopeAndNoHiddenReturnsInputUntouched() {
        let packets = [packet(radio: a), packet(radio: b)]
        let filtered = AnalyticsRadioFilter.apply(
            packets, scope: .all, channels: [], hidden: [])
        XCTAssertEqual(filtered.count, 2)
    }
}
