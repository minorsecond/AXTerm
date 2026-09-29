import XCTest
@testable import AXTerm

/// The one question the radio form asks about reaching a radio.
///
/// It used to be two: a Transport picker, and a second one inside the sound
/// modem's fields for USB or Wi-Fi. Flattening them is only safe if the flat
/// list can still say everything the pair could, so that is what these pin.
final class RadioLinkChoiceTests: XCTestCase {

    /// Every state the two pickers could express has exactly one row in the
    /// flat list, and that row maps back to the same state. A combination
    /// with no row would be a radio the operator could no longer configure.
    func testEveryTransportAndModemLinkHasARow() {
        for transport in TransportSelection.allCases {
            for rigLink in [ModemRigLink.usb, .lan] {
                let choice = RadioLinkChoice.of(transport: transport, rigLink: rigLink)

                XCTAssertEqual(choice.transport, transport,
                               "\(transport)/\(rigLink) landed on \(choice)")
                if transport == .modem {
                    XCTAssertEqual(choice.rigLink, rigLink,
                                   "the modem's own link must survive the flattening")
                } else {
                    XCTAssertNil(choice.rigLink,
                                 "a TNC transport has no modem link to set")
                }
            }
        }
    }

    /// A TNC transport must not silently rewrite the modem link, or picking
    /// Network and coming back would land a Wi-Fi radio on USB.
    func testChoosingATNCTransportLeavesTheModemLinkAlone() {
        for transport in [TransportSelection.network, .serial, .ble] {
            XCTAssertNil(RadioLinkChoice.of(transport: transport, rigLink: .lan).rigLink)
            XCTAssertNil(RadioLinkChoice.of(transport: transport, rigLink: .usb).rigLink)
        }
    }

    /// Two rows reading the same would put the operator back where the
    /// nested pickers left them.
    func testEveryRowReadsDifferently() {
        let titles = RadioLinkChoice.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "duplicate titles in \(titles)")

        let summaries = RadioLinkChoice.allCases.map(\.summary)
        XCTAssertEqual(Set(summaries).count, summaries.count)

        for choice in RadioLinkChoice.allCases {
            XCTAssertFalse(choice.title.isEmpty, "\(choice)")
            XCTAssertGreaterThan(choice.summary.count, 20, "\(choice) explains nothing")
        }
    }

    /// The summary has to answer "is this a TNC or not?", because that is
    /// the distinction the old wording buried.
    func testTheSummarySaysWhetherThereIsATNC() {
        XCTAssertTrue(RadioLinkChoice.modemUSB.summary.hasPrefix("No TNC"))
        XCTAssertTrue(RadioLinkChoice.modemWiFi.summary.hasPrefix("No TNC"))
        for choice in [RadioLinkChoice.network, .serial, .ble] {
            XCTAssertTrue(choice.summary.contains("TNC"), "\(choice): \(choice.summary)")
            XCTAssertFalse(choice.summary.hasPrefix("No TNC"), "\(choice)")
        }
    }

    /// On a Mac every row is offered; the sound modem is only restricted
    /// where it cannot run.
    func testAMacOffersEveryRow() {
        #if os(macOS)
        XCTAssertEqual(Set(RadioLinkChoice.selectable(including: .network)),
                       Set(RadioLinkChoice.allCases))
        #else
        // Elsewhere the modem rows show only for a radio already set to one,
        // so its operator can see and change it.
        XCTAssertFalse(RadioLinkChoice.selectable(including: .network).contains(.modemUSB))
        XCTAssertTrue(RadioLinkChoice.selectable(including: .modemWiFi).contains(.modemWiFi))
        #endif
    }
}
