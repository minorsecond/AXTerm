import XCTest
@testable import AXTerm

/// What the rest of the channel sees when we place an object.
///
/// The symbol is the only thing most receiving stations will ever render, so
/// a mislabelled one puts a house where the operator marked a road closure —
/// which is precisely what the first version of this picker did. `/-` is a
/// House, `/h` is a Hospital and not a shelter, and `\0` is the
/// IRLP/Echolink circle. All three were caught by transmitting them on the
/// rig and reading Direwolf's decode, not by reading a table.
final class APRSObjectSymbolTests: XCTestCase {

    /// Direwolf's own label for each symbol, captured on the RF rig
    /// (`TestRig/scripts/axterm_object_onair.py`, 2026-09-09). A different
    /// implementation's words, so this cannot be satisfied by agreeing with
    /// ourselves.
    private let asDirewolfReadsThem: [APRSPlaceObjectSheet.Choice: String] = [
        .incident:    "Emergency!",
        .obstruction: "Wreck or Obstruction",
        .aidStation:  "Red Cross",
        .fire:        "FIRE",
        .water:       "Water Station or other H2O",
        .hospital:    "Hospital",
        .shelter:     "overlayed shelter",
        .portable:    "Portable operation (tent)",
    ]

    /// Every choice we offer must still mean, to somebody else, what we tell
    /// the operator it means.
    func testWhatWeCallEachSymbolIsWhatOthersRead() throws {
        for choice in APRSPlaceObjectSheet.Choice.allCases {
            let theirs = try XCTUnwrap(asDirewolfReadsThem[choice],
                                       "\(choice.rawValue) was added without being "
                                       + "verified on the air — run axterm_object_onair.py")
            let ours = choice.asOthersSeeIt.lowercased()
            XCTAssertTrue(theirs.lowercased().contains(ours)
                          || ours.contains(theirs.lowercased().split(separator: "(").first!
                                              .trimmingCharacters(in: .whitespaces)),
                          "\(choice.rawValue): we say \u{201C}\(choice.asOthersSeeIt)\u{201D}, "
                          + "Direwolf says \u{201C}\(theirs)\u{201D}")
        }
    }

    /// The three that were wrong, pinned so they cannot come back.
    func testTheSymbolsThatWereWrongAreNotUsed() {
        let used = Set(APRSPlaceObjectSheet.Choice.allCases.map {
            String($0.symbol.0) + String($0.symbol.1)
        })
        XCTAssertFalse(used.contains("/-"), "/- is a House, not a road closure")
        XCTAssertFalse(used.contains("\\0"), "\\0 is the IRLP/Echolink circle, not a staging area")
        // /h stays, but as Hospital — which is what it is.
        XCTAssertEqual(APRSPlaceObjectSheet.Choice.hospital.label, "Hospital")
    }

    /// A symbol we offer has to survive the encoder and come back as itself.
    func testEveryOfferedSymbolRoundTripsThroughTheEncoder() throws {
        for choice in APRSPlaceObjectSheet.Choice.allCases {
            let (table, code) = choice.symbol
            let info = APRSObjectReport.objectInfo(
                name: "PROBE", live: true, latitude: 39.6117, longitude: -104.7317,
                symbolTable: table, symbolCode: code,
                at: Date(timeIntervalSince1970: 1_757_419_200))
            let back = try XCTUnwrap(APRSObjectReport.parse(info: Data(info.utf8)),
                                     "\(choice.rawValue) produced an unparseable frame")
            XCTAssertEqual(back.symbolTable, table, choice.rawValue)
            XCTAssertEqual(back.symbolCode, code, choice.rawValue)
        }
    }
}
