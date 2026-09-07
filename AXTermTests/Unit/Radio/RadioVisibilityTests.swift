import XCTest
@testable import AXTerm

/// The universal view and its switches: every radio's traffic interleaved by
/// default, any radio hideable everywhere, and a one-radio station that never
/// sees a word of it.
final class RadioVisibilityTests: XCTestCase {

    private let base = RadioID.primary
    private let uhf = RadioID(rawValue: "uhf")

    private func packet(_ call: String, radio: RadioID?) -> Packet {
        Packet(timestamp: Date(), from: AX25Address(call: call), to: AX25Address(call: "CQ"),
               frameType: .ui, control: 0x03, info: Data([0x41]), rawAx25: Data([0x01]),
               radioID: radio)
    }

    func testNothingHiddenShowsEveryRadio() {
        let packets = [packet("A", radio: base), packet("B", radio: uhf), packet("C", radio: nil)]
        let shown = PacketFilter.filter(packets: packets, search: "", filters: PacketFilters(), stationCall: nil)
        XCTAssertEqual(shown.count, 3)
    }

    func testAHiddenRadiosFramesAreNotShownAndLegacyFramesBelongToThePrimary() {
        let packets = [packet("A", radio: base), packet("B", radio: uhf), packet("C", radio: nil)]
        let shown = PacketFilter.filter(packets: packets, search: "", filters: PacketFilters(),
                                        stationCall: nil, hiddenRadios: [base])
        XCTAssertEqual(shown.map(\.fromDisplay), ["B"], "the primary's frames, stamped or legacy, are hidden")
    }

    /// A station is hidden only when every radio that heard it is hidden, so
    /// one heard on both radios stays one dot on the map.
    @MainActor func testAStationStaysVisibleWhileAnyRadioThatHeardItIsShown() async {
        let engine = PacketEngine(settings: AppSettingsStore(defaults: UserDefaults(suiteName: "RadioVisibilityTests.\(UUID().uuidString)")!))
        var both = Station(call: "K0NTS", lastHeard: Date(), heardCount: 2)
        both.perRadio = [base: .init(lastHeard: Date(), heardCount: 1, lastVia: []),
                         uhf: .init(lastHeard: Date(), heardCount: 1, lastVia: [])]
        var onlyBase = Station(call: "W0ARP", lastHeard: Date(), heardCount: 1)
        onlyBase.perRadio = [base: .init(lastHeard: Date(), heardCount: 1, lastVia: [])]
        let legacy = Station(call: "N0CALL", lastHeard: Date(), heardCount: 1)

        XCTAssertTrue(engine.isVisible(both))
        engine.hiddenRadioIDs = [base]
        XCTAssertTrue(engine.isVisible(both), "still heard on UHF")
        XCTAssertFalse(engine.isVisible(onlyBase))
        XCTAssertFalse(engine.isVisible(legacy), "a station from before radios existed was heard on the primary")
        engine.hiddenRadioIDs = []
        XCTAssertTrue(engine.isVisible(legacy))
    }

    /// A one-radio station has no names, so no row names a radio.
    func testTheRadioColumnDoesNotExistWithOneRadio() {
        let row = PacketRowViewModel.fromPacket(packet("A", radio: base))
        XCTAssertNil(row.radioName)
        let named = PacketRowViewModel.fromPacket(packet("A", radio: uhf), radioNames: [uhf: "IC-705", base: "Base"])
        XCTAssertEqual(named.radioName, "IC-705")
        let legacy = PacketRowViewModel.fromPacket(packet("A", radio: nil), radioNames: [uhf: "IC-705", base: "Base"])
        XCTAssertEqual(legacy.radioName, "Base", "frames from before radios existed belong to the primary")
    }

    /// The scope line names the radios still shown, and only then.
    func testTheStatusLineNamesTheVisibleRadiosOnlyWhenSomeAreHidden() {
        let filters = PacketFilters()
        XCTAssertEqual(filters.statusLine(shown: 3, total: 3, station: nil), "3 frames")
        XCTAssertEqual(filters.statusLine(shown: 3, total: 3, station: nil, radios: nil), "3 frames")
        XCTAssertEqual(filters.statusLine(shown: 2, total: 3, station: nil, radios: ["IC-705"]),
                       "2 of 3 frames \u{b7} on IC-705")
    }
}
