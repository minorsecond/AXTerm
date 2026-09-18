import XCTest
@testable import AXTerm

/// "Sent" is two events, and the strip used to show only the first.
///
/// A frame is handed to the radio the instant the operator clicks; it reaches
/// the air when the channel is clear and the transmitter keys, which on a busy
/// channel is seconds later — and sometimes never, because the modem gives up
/// after `maxChannelWaitSeconds` and discards what it was holding. A line that
/// appeared immediately either way left the operator unable to tell "my query
/// went unanswered" from "my query never went out".
@MainActor
final class MapTrafficPendingTests: XCTestCase {

    private let modem = RadioID(rawValue: "ic705")
    private let tnc = RadioID(rawValue: "direwolf")

    private func line(_ summary: String, radio: RadioID,
                      transmit: MapTrafficFeed.TransmitState?) -> MapTrafficFeed.Line {
        MapTrafficFeed.Line(id: UUID(), at: Date(), from: "K0EPI-7", to: "APZAXT",
                            via: "", summary: summary, isOurs: true, isForUs: false,
                            radio: radio, transmit: transmit)
    }

    private func summaries(_ feed: MapTrafficFeed) -> [String: MapTrafficFeed.TransmitState?] {
        Dictionary(uniqueKeysWithValues: feed.lines.map { ($0.summary, $0.transmit) })
    }

    func testAFrameKeyedResolvesTheOldestPendingLine() {
        let feed = MapTrafficFeed()
        feed.record(line("first", radio: modem, transmit: .pending))
        feed.record(line("second", radio: modem, transmit: .pending))

        feed.resolveTransmits(radio: modem, onAir: 1, dropped: 0)

        // Counts, not identities: the transmitter is strictly in order, so
        // the first frame handed over is the one that went out.
        XCTAssertEqual(summaries(feed)["first"], .onAir)
        XCTAssertEqual(summaries(feed)["second"], .pending)
    }

    func testGivingUpMarksTheFrameNeverSent() {
        let feed = MapTrafficFeed()
        feed.record(line("query", radio: modem, transmit: .pending))

        feed.resolveTransmits(radio: modem, onAir: 0, dropped: 1)

        XCTAssertEqual(summaries(feed)["query"], .dropped)
    }

    /// One radio keying says nothing about another radio's queue.
    func testOneRadiosOutcomeLeavesAnothersAlone() {
        let feed = MapTrafficFeed()
        feed.record(line("on the modem", radio: modem, transmit: .pending))
        feed.record(line("on the TNC", radio: tnc, transmit: .pending))

        feed.resolveTransmits(radio: modem, onAir: 1, dropped: 0)

        XCTAssertEqual(summaries(feed)["on the modem"], .onAir)
        XCTAssertEqual(summaries(feed)["on the TNC"], .pending)
    }

    /// A hardware TNC accepts KISS bytes and reports nothing further, so
    /// there is nothing to promise: those lines carry no state at all rather
    /// than a "pending" that would never resolve.
    func testALineWithNoStateIsNeverTouched() {
        let feed = MapTrafficFeed()
        feed.record(line("beacon", radio: tnc, transmit: nil))

        feed.resolveTransmits(radio: tnc, onAir: 1, dropped: 0)

        XCTAssertEqual(summaries(feed)["beacon"], MapTrafficFeed.TransmitState?.none)
    }

    /// Already-resolved lines are history and must not be rewritten by a
    /// later report.
    func testAResolvedLineStays() {
        let feed = MapTrafficFeed()
        feed.record(line("done", radio: modem, transmit: .onAir))
        feed.record(line("waiting", radio: modem, transmit: .pending))

        feed.resolveTransmits(radio: modem, onAir: 0, dropped: 1)

        XCTAssertEqual(summaries(feed)["done"], .onAir)
        XCTAssertEqual(summaries(feed)["waiting"], .dropped)
    }

    /// The modem discards everything it holds when it gives up, so a report
    /// carrying both is a drop followed by a fresh queue that got out.
    func testADropIsResolvedBeforeASendInTheSameReport() {
        let feed = MapTrafficFeed()
        feed.record(line("lost", radio: modem, transmit: .pending))
        feed.record(line("made it", radio: modem, transmit: .pending))

        feed.resolveTransmits(radio: modem, onAir: 1, dropped: 1)

        XCTAssertEqual(summaries(feed)["lost"], .dropped)
        XCTAssertEqual(summaries(feed)["made it"], .onAir)
    }
}

/// Telling a transmission apart from our own frame coming home.
///
/// A digipeater repeating us puts our callsign back on the air, so the source
/// alone cannot say who transmitted. Reading it as "TX" made one message look
/// like three transmissions and hid the interesting part: two digipeaters
/// heard us (2026-09-17).
final class MapTrafficOwnEchoTests: XCTestCase {

    private let radio = RadioID.primary
    private let now = Date(timeIntervalSince1970: 100_000)

    @MainActor
    func testOurFrameComingBackIsNotCountedAsATransmission() {
        let feed = MapTrafficFeed()
        feed.absorb([heardBack()], attribution: { _ in
            MapTrafficFeed.Attribution(isOurs: true, isForUs: false)
        })

        let line = feed.lines(for: nil, visible: [radio]).first
        XCTAssertEqual(line?.isOurs, true, "it does carry our callsign")
        XCTAssertEqual(line?.wasTransmitted, false, "but we did not put this copy on the air")
    }

    @MainActor
    func testWhatWeActuallySentIsMarkedTransmitted() {
        let feed = MapTrafficFeed()
        feed.record(MapTrafficFeed.Line(
            id: UUID(), at: now, from: "K0EPI-5", to: "APZAXT",
            via: "WIDE1-1,WIDE2-1", summary: ":AD1CT :howdy{1",
            isOurs: true, wasTransmitted: true, isForUs: false, radio: radio))

        XCTAssertEqual(feed.lines(for: nil, visible: [radio]).first?.wasTransmitted, true)
    }

    /// One send, two digipeaters, three lines — and exactly one of them is a
    /// transmission.
    @MainActor
    func testOneSendRepeatedTwiceShowsOneTransmission() {
        let feed = MapTrafficFeed()
        feed.record(MapTrafficFeed.Line(
            id: UUID(), at: now, from: "K0EPI-5", to: "APZAXT",
            via: "WIDE1-1,WIDE2-1", summary: "howdy",
            isOurs: true, wasTransmitted: true, isForUs: false, radio: radio))
        feed.absorb([heardBack(via: "W0NED"), heardBack(via: "AD1CT")], attribution: { _ in
            MapTrafficFeed.Attribution(isOurs: true, isForUs: false)
        })

        let lines = feed.lines(for: nil, visible: [radio])
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.filter(\.wasTransmitted).count, 1)
    }

    private func heardBack(via: String = "AD1CT") -> Packet {
        Packet(timestamp: now,
               from: AX25Address(call: "K0EPI", ssid: 5),
               to: AX25Address(call: "APZAXT"),
               via: [AX25Address(call: via, repeated: true),
                     AX25Address(call: "WIDE1", repeated: true)],
               frameType: .ui, control: 0x03, pid: 0xF0,
               info: Data(":AD1CT    :howdy{1".utf8),
               rawAx25: Data([0x00]),
               radioID: radio, direction: .rx)
    }
}
