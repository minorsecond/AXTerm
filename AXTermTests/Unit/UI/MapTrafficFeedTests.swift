import XCTest
@testable import AXTerm

/// What the map's traffic strip shows, and in what order.
@MainActor
final class MapTrafficFeedTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func packet(_ from: String, to: String = "APRS", info: String = "",
                        via: [AX25Address] = [], at: TimeInterval = 0,
                        radio: RadioID? = nil) -> Packet {
        Packet(timestamp: t0.addingTimeInterval(at),
               from: AX25Address(call: from), to: AX25Address(call: to),
               via: via, frameType: .ui, control: 0x03,
               info: Data(info.utf8), rawAx25: Data([0x01]), radioID: radio)
    }

    /// Nothing this station sent, and nothing addressed to it.
    private func heard(_: Packet) -> MapTrafficFeed.Attribution {
        MapTrafficFeed.Attribution(isOurs: false, isForUs: false)
    }

    func testNewestFirst() async throws {
        let feed = MapTrafficFeed()
        feed.absorb([packet("A", at: 0), packet("B", at: 1), packet("C", at: 2)], attribution: heard)
        XCTAssertEqual(feed.lines.map(\.from), ["C", "B", "A"],
                       "a glance at a strip reads from the top")
    }

    /// The strip is a glance, not the Packets page: it keeps a short tail.
    func testOnlyTheTailIsKept() async throws {
        let feed = MapTrafficFeed()
        let many = (0..<(MapTrafficFeed.capacity + 20)).map { packet("S\($0)", at: Double($0)) }
        feed.absorb(many, attribution: heard)
        XCTAssertEqual(feed.lines(for: nil, visible: []).count, MapTrafficFeed.capacity)
        XCTAssertEqual(feed.lines.first?.from, "S\(MapTrafficFeed.capacity + 19)", "newest survives")
    }

    /// Only digipeaters that actually repeated the frame are shown. An
    /// unused entry is a request, and printing it would claim a path the
    /// frame never took.
    func testOnlyUsedDigipeatersAreNamed() {
        let used = AX25Address(call: "WIDE1", ssid: 1, repeated: true)
        let requested = AX25Address(call: "WIDE2", ssid: 2, repeated: false)
        XCTAssertEqual(MapTrafficFeed.via(packet("A", via: [used, requested])), "WIDE1-1")
        XCTAssertEqual(MapTrafficFeed.via(packet("A", via: [requested])), "",
                       "nothing repeated it, so it was heard direct")
    }

    /// A frame with no printable payload — an RR, a SABM — is still traffic
    /// worth a line while watching a connect.
    func testAFrameWithNoTextIsNamedByItsType() {
        XCTAssertEqual(MapTrafficFeed.summary(packet("A", info: "")), "UI")
        XCTAssertEqual(MapTrafficFeed.summary(packet("A", info: "hello")), "hello")
    }

    /// Newlines would break the one-line row.
    func testSummaryIsFlattenedToOneLine() {
        let summary = MapTrafficFeed.summary(packet("A", info: "first\r\nsecond"))
        XCTAssertFalse(summary.contains("\n"))
        XCTAssertFalse(summary.contains("\r"))
        XCTAssertTrue(summary.contains("first"))
        XCTAssertTrue(summary.contains("second"))
    }

    func testOurOwnTrafficIsMarked() async throws {
        let feed = MapTrafficFeed()
        feed.absorb([packet("K0EPI", at: 0), packet("W0ARP", at: 1)]) {
            MapTrafficFeed.Attribution(isOurs: $0.from?.call == "K0EPI", isForUs: false)
        }
        XCTAssertEqual(feed.lines.first(where: { $0.from == "K0EPI" })?.isOurs, true)
        XCTAssertEqual(feed.lines.first(where: { $0.from == "W0ARP" })?.isOurs, false)
    }

    // MARK: - Our own transmissions

    private func sent(_ from: String, to: String, at: TimeInterval,
                      radio: RadioID? = nil) -> MapTrafficFeed.Line {
        MapTrafficFeed.Line(id: UUID(), at: t0.addingTimeInterval(at), from: from, to: to,
                            via: "", summary: "beacon", isOurs: true, isForUs: false,
                            radio: radio)
    }

    /// The reason for `record` at all: a frame we sent never enters the
    /// engine's packet log, so a strip built only from that log showed a busy
    /// channel and no sign of our own beacon.
    func testTransmissionsAppearInTimeOrderWithReceivedTraffic() async throws {
        let feed = MapTrafficFeed()
        feed.absorb([packet("A", at: 0), packet("C", at: 2)], attribution: heard)
        feed.record(sent("K0EPI-7", to: "APZAXT", at: 1))
        XCTAssertEqual(feed.lines.map(\.from), ["C", "K0EPI-7", "A"])
        XCTAssertEqual(feed.lines.first(where: { $0.from == "K0EPI-7" })?.isOurs, true)
    }

    /// A later batch of received frames must not discard what we sent between
    /// batches — the two lists are merged, not replaced.
    func testAFreshBatchKeepsEarlierTransmissions() async throws {
        let feed = MapTrafficFeed()
        feed.record(sent("K0EPI-7", to: "APZAXT", at: 1))
        feed.absorb([packet("A", at: 0), packet("B", at: 3)], attribution: heard)
        XCTAssertEqual(feed.lines.map(\.from), ["B", "K0EPI-7", "A"])
    }

    // MARK: - One radio is one channel

    func testAHiddenRadiosTrafficIsNotShown() async throws {
        let aprs = RadioID(rawValue: "aprs")
        let packetRadio = RadioID(rawValue: "ax25")
        let feed = MapTrafficFeed()
        feed.absorb([packet("A", at: 0, radio: aprs),
                     packet("B", at: 1, radio: packetRadio)], attribution: heard)
        XCTAssertEqual(feed.lines(for: nil, visible: [aprs]).map(\.from), ["A"],
                       "hiding the packet radio hides its traffic with its stations")
    }

    func testATabShowsOnlyItsOwnRadio() async throws {
        let aprs = RadioID(rawValue: "aprs")
        let packetRadio = RadioID(rawValue: "ax25")
        let feed = MapTrafficFeed()
        feed.absorb([packet("A", at: 0, radio: aprs),
                     packet("B", at: 1, radio: packetRadio)], attribution: heard)
        XCTAssertEqual(feed.lines(for: packetRadio, visible: [aprs, packetRadio]).map(\.from), ["B"])
    }
}

/// Which radio's frames a strip shows.
final class MapTrafficScopeTests: XCTestCase {

    private let a = RadioID(rawValue: "a")
    private let b = RadioID(rawValue: "b")

    func testASelectedTabIsExact() {
        XCTAssertTrue(MapTrafficScope.shows(radio: a, selected: a, visible: [a, b]))
        XCTAssertFalse(MapTrafficScope.shows(radio: b, selected: a, visible: [a, b]))
    }

    /// A frame with no radio cannot belong to a specific tab.
    func testAnUnattributedFrameIsNotClaimedByATab() {
        XCTAssertFalse(MapTrafficScope.shows(radio: nil, selected: a, visible: [a]))
    }

    /// …but on the pooled view it is shown rather than dropped: frames stored
    /// before radios existed have no attribution, and dropping them would
    /// empty the strip on a station that has only ever had one radio.
    func testAnUnattributedFrameSurvivesThePooledView() {
        XCTAssertTrue(MapTrafficScope.shows(radio: nil, selected: nil, visible: [a]))
    }

    func testThePooledViewIsStillLimitedToVisibleRadios() {
        XCTAssertTrue(MapTrafficScope.shows(radio: a, selected: nil, visible: [a]))
        XCTAssertFalse(MapTrafficScope.shows(radio: b, selected: nil, visible: [a]))
    }

    /// Nothing configured yet is not a reason to show nothing.
    func testWithNoVisibleRadiosEverythingShows() {
        XCTAssertTrue(MapTrafficScope.shows(radio: b, selected: nil, visible: []))
    }
}

/// Which frames are addressed to this station.
final class TrafficAddressingTests: XCTestCase {

    private let ours = ["K0EPI-7", "K0EPI-1"]

    func testAnAX25FrameToOneOfOurAddresses() {
        XCTAssertTrue(TrafficAddressing.isForUs(
            destinationAnswered: true, info: Data(), ours: ours))
    }

    /// The one the AX.25 destination cannot answer: an APRS message rides a
    /// tocall (`APZAXT`) and names its recipient in the payload.
    func testAnAPRSMessageToUs() {
        let info = Data(":K0EPI-7  :hello{12".utf8)
        XCTAssertTrue(TrafficAddressing.isForUs(
            destinationAnswered: false, info: info, ours: ours))
    }

    func testAnAPRSMessageToSomebodyElse() {
        let info = Data(":W0ARP-1  :hello{12".utf8)
        XCTAssertFalse(TrafficAddressing.isForUs(
            destinationAnswered: false, info: info, ours: ours))
    }

    func testAnAckToUsCounts() {
        let info = Data(":K0EPI-7  :ack12".utf8)
        XCTAssertTrue(TrafficAddressing.isForUs(
            destinationAnswered: false, info: info, ours: ours))
    }

    /// A bulletin goes to the whole channel. Tinting it would tint most of
    /// the strip and mean nothing.
    func testABulletinIsNotAddressedToUs() {
        let info = Data(":BLN1     :net tonight".utf8)
        XCTAssertFalse(TrafficAddressing.isForUs(
            destinationAnswered: false, info: info, ours: ours))
    }

    func testAPositionReportIsNotAddressedToAnyone() {
        let info = Data("!3930.00N/10515.00W-".utf8)
        XCTAssertFalse(TrafficAddressing.isForUs(
            destinationAnswered: false, info: info, ours: ours))
    }
}
