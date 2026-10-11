import XCTest
@testable import AXTerm

/// Switching a radio between APRS and Packet asks first, and says the radio
/// is not retuned (retest 2026-10-10, finding 14). The switch changes what
/// AXTerm does on the radio, never its frequency.
final class ChannelSwitchPromptTests: XCTestCase {

    func testSwitchingToAPRSNamesTheFrequencyToSet() {
        let prompt = ChannelSwitchPrompt(radioName: "IC-705", to: .aprs)
        XCTAssertEqual(prompt.title, "Switch IC-705 to APRS?")
        XCTAssertEqual(prompt.confirmLabel, "Switch to APRS")
        XCTAssertEqual(prompt.message, "AXTerm will send APRS on IC-705 and stop answering packet calls on it. "
                       + "It does not retune the radio: set it to your APRS frequency "
                       + "(144.390 MHz in North America) yourself.")
    }

    /// There is no single packet channel to name.
    func testSwitchingToPacketNamesNoFrequency() {
        let prompt = ChannelSwitchPrompt(radioName: "ID-50", to: .packet)
        XCTAssertEqual(prompt.title, "Switch ID-50 to Packet?")
        XCTAssertEqual(prompt.confirmLabel, "Switch to Packet")
        XCTAssertEqual(prompt.message, "AXTerm will use ID-50 for packet sessions and stop sending APRS on it. "
                       + "It does not retune the radio: set it to your packet channel yourself.")
    }
}
