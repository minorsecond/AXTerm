import XCTest
@testable import AXTerm

/// Whether the Messages screen may send, and which radios it could switch.
/// With no radio on APRS it does not offer to send at all (home retest,
/// 2026-10-10: a message from the iPad on Packet showed "Sent").
final class APRSSendAvailabilityTests: XCTestCase {

    private func radio(_ id: String, _ channel: RadioChannel, enabled: Bool = true) -> RadioProfile {
        var r = RadioProfile(id: RadioID(rawValue: id), name: id)
        r.enabled = enabled
        channel.apply(to: &r)
        return r
    }

    func testARadioOnAPRSMeansReady() {
        XCTAssertEqual(APRSSendAvailability.of([radio("tnc4", .aprs)]), .ready)
        XCTAssertEqual(APRSSendAvailability.of([radio("705", .packet), radio("id50", .aprs)]), .ready)
    }

    func testOnlyPacketRadiosOfferToSwitchThem() {
        XCTAssertEqual(APRSSendAvailability.of([radio("tnc4", .packet)]),
                       .noAPRSRadio(switchable: [RadioID(rawValue: "tnc4")]))
        XCTAssertEqual(APRSSendAvailability.of([radio("tnc4", .packet), radio("off", .packet, enabled: false)]),
                       .noAPRSRadio(switchable: [RadioID(rawValue: "tnc4")]),
                       "a switched-off radio is not offered")
    }

    func testNoRadiosAtAll() {
        XCTAssertEqual(APRSSendAvailability.of([]), .noAPRSRadio(switchable: []))
    }

    func testTheNoteSaysWhy() {
        XCTAssertTrue(APRSSendAvailability.noAPRSRadio(switchable: []).note?.contains("APRS") == true)
        XCTAssertNil(APRSSendAvailability.ready.note)
    }
}
