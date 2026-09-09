import XCTest
@testable import AXTerm

/// Which radio a station is answered on.
final class APRSRadioChoiceTests: XCTestCase {

    private let aprs = RadioID(rawValue: "aprs")
    private let packetRadio = RadioID(rawValue: "ax25")
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func station(_ call: String, heard: [(RadioID, TimeInterval)]) -> Station {
        var s = Station(call: call)
        for (radio, ago) in heard {
            s.perRadio[radio] = Station.RadioObservation(
                lastHeard: now.addingTimeInterval(-ago), heardCount: 1, lastVia: [])
        }
        return s
    }

    /// Two radios are two channels: a station worked on one frequency is not
    /// reachable by transmitting on the other.
    func testTheRadioThatHeardThemWins() {
        let stations = [station("W0ARP", heard: [(packetRadio, 60), (aprs, 600)])]
        XCTAssertEqual(
            APRSRadioChoice.radioThatHeard("W0ARP", in: stations, now: now,
                                           eligible: [aprs, packetRadio]),
            packetRadio)
    }

    /// A radio that heard them but is now disconnected is not an answer.
    func testOnlyAnEligibleRadioCounts() {
        let stations = [station("W0ARP", heard: [(packetRadio, 60)])]
        XCTAssertNil(APRSRadioChoice.radioThatHeard("W0ARP", in: stations, now: now,
                                                    eligible: [aprs]))
    }

    /// Heard yesterday does not decide today's transmission.
    func testAStaleHearingDoesNotDecide() {
        let stations = [station("W0ARP", heard: [(aprs, APRSRadioChoice.window + 60)])]
        XCTAssertNil(APRSRadioChoice.radioThatHeard("W0ARP", in: stations, now: now,
                                                    eligible: [aprs]))
    }

    func testAStationNeverHeardHasNoRadio() {
        XCTAssertNil(APRSRadioChoice.radioThatHeard("W0ARP", in: [], now: now,
                                                    eligible: [aprs]))
    }

    func testTheCallsignMatchIsCaseInsensitive() {
        let stations = [station("W0ARP-9", heard: [(aprs, 30)])]
        XCTAssertEqual(
            APRSRadioChoice.radioThatHeard("w0arp-9", in: stations, now: now, eligible: [aprs]),
            aprs)
    }
}
