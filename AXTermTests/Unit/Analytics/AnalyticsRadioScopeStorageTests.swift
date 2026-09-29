import XCTest
import GRDB
@testable import AXTerm

/// What the analytics page reads back out of the database.
///
/// The page scopes itself to the radios the operator has left visible, and it
/// refuses to draw an APRS destination as a station. Both decisions are made
/// against stored rows, so both depend on the read carrying the radio that
/// heard the frame and the bytes the frame contained. It carried neither:
/// every stored packet came back with no radio, which the scope reads as the
/// primary radio, and with a payload of zeros the right length. Hiding the
/// primary radio emptied the page; showing it drew every other radio's traffic
/// as well, Mic-E destinations included (2026-09-17).
final class AnalyticsRadioScopeStorageTests: XCTestCase {

    private let direwolf = RadioID.primary
    private let handheld = RadioID(rawValue: "705-A1B2C3")

    private let window = DateInterval(
        start: Date(timeIntervalSince1970: 0),
        end: Date(timeIntervalSince1970: 10_000))

    // MARK: - The read

    func testAStoredPacketComesBackBelongingToTheRadioThatHeardIt() throws {
        let store = try makeStore()
        try store.save(micEBeacon(from: "WA0DE-9", destination: "S9RSVQ", radio: handheld, at: 100))
        try store.save(nodeBeacon(from: "KE0NCQ", destination: "ID", radio: direwolf, at: 200))

        let loaded = try store.loadPackets(in: window)

        XCTAssertEqual(
            loaded.map { $0.radioID },
            [handheld, direwolf],
            "the radio that heard each frame must survive the round trip")
    }

    func testAStoredPacketComesBackWithThePayloadItCarried() throws {
        let store = try makeStore()
        try store.save(micEBeacon(from: "WA0DE-9", destination: "S9RSVQ", radio: handheld, at: 100))

        let loaded = try store.loadPackets(in: window)

        XCTAssertEqual(
            loaded.first?.info.first, 0x60,
            "the APRS data type is the first payload byte, and it is the only "
            + "thing that marks a Mic-E destination as a coordinate")
    }

    func testADatabaseWithoutTheRadioColumnStillReads() throws {
        // A snapshot kept from a build that predates separable radios, opened
        // the way the health and routing contract tests open theirs: straight
        // from disk, never migrated.
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let store = SQLitePacketStore(dbQueue: queue)
        // Written while the column exists, then taken away: the row is left
        // exactly as an older build would have written it.
        try store.save(nodeBeacon(from: "KE0NCQ", destination: "DRLNOD", radio: direwolf, at: 100))
        try queue.write { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_packets_radio_receivedAt")
            try db.execute(sql: "ALTER TABLE packets DROP COLUMN radioID")
        }

        let loaded = try store.loadPackets(in: window)

        XCTAssertEqual(loaded.count, 1, "naming a missing column must not fail the whole read")
        XCTAssertEqual(
            loaded.first?.radioID, .primary,
            "a row from before radios were separable belonged to the only radio there was")

        let aggregated = try store.aggregateAnalytics(
            in: window, bucket: .hour, calendar: utcCalendar(),
            options: options(selection: AnalyticsRadioSelection(hidden: [handheld])))
        XCTAssertEqual(
            aggregated.summary.totalPackets, 1,
            "hiding a radio the database has never heard of removes nothing")
    }

    // MARK: - Scoping the page

    func testHidingOneRadioLeavesTheOtherRadiosTrafficOnThePage() throws {
        let store = try makeStore()
        try store.save(micEBeacon(from: "WA0DE-9", destination: "S9RSVQ", radio: handheld, at: 100))
        try store.save(nodeBeacon(from: "KE0NCQ", destination: "ID", radio: direwolf, at: 200))

        let visible = AnalyticsRadioFilter.apply(
            try store.loadPackets(in: window),
            scope: .all, channels: [], hidden: [direwolf])

        XCTAssertEqual(
            visible.map { $0.from?.display }, ["WA0DE-9"],
            "hiding one radio must not take the other radio's history with it")
    }

    func testTheGraphKeepsTheSenderAndNeverDrawsAMicEDestination() throws {
        let store = try makeStore()
        try store.save(micEBeacon(from: "WA0DE-9", destination: "S9RSVQ", radio: handheld, at: 100))

        let graph = NetworkGraphBuilder.buildClassified(
            packets: try store.loadPackets(in: window),
            options: graphOptions())

        let labels = Set(graph.nodes.map(\.id))
        XCTAssertTrue(labels.contains("WA0DE-9"), "the sender is a real station")
        XCTAssertFalse(
            labels.contains("S9RSVQ"),
            "a Mic-E destination is the sender's latitude, not somewhere to send to")
    }

    // MARK: - The stored aggregation

    func testTheStoredAggregationDropsAHiddenRadio() throws {
        let store = try makeStore()
        try store.save(nodeBeacon(from: "KE0NCQ", destination: "DRLNOD", radio: direwolf, at: 100))
        try store.save(nodeBeacon(from: "K0NTS-7", destination: "DRLNOD", radio: handheld, at: 200))

        let scoped = try store.aggregateAnalytics(
            in: window, bucket: .hour, calendar: utcCalendar(),
            options: options(selection: AnalyticsRadioSelection(hidden: [handheld])))

        XCTAssertEqual(scoped.summary.totalPackets, 1, "only the visible radio's frame counts")
        XCTAssertEqual(
            scoped.topTalkers.map(\.label), ["KE0NCQ"],
            "the hidden radio's sender must not appear")
    }

    func testTheStoredAggregationNarrowsToASelectedChannel() throws {
        let store = try makeStore()
        try store.save(nodeBeacon(from: "KE0NCQ", destination: "DRLNOD", radio: direwolf, at: 100))
        try store.save(nodeBeacon(from: "K0NTS-7", destination: "DRLNOD", radio: handheld, at: 200))

        let scoped = try store.aggregateAnalytics(
            in: window, bucket: .hour, calendar: utcCalendar(),
            options: options(selection: AnalyticsRadioSelection(channelRadios: [handheld])))

        XCTAssertEqual(scoped.topTalkers.map(\.label), ["K0NTS-7"])
    }

    func testTheStoredAggregationCountsEveryRadioWhenNoneIsHidden() throws {
        let store = try makeStore()
        try store.save(nodeBeacon(from: "KE0NCQ", destination: "DRLNOD", radio: direwolf, at: 100))
        try store.save(nodeBeacon(from: "K0NTS-7", destination: "DRLNOD", radio: handheld, at: 200))

        let everything = try store.aggregateAnalytics(
            in: window, bucket: .hour, calendar: utcCalendar(),
            options: options(selection: .everything))

        XCTAssertEqual(everything.summary.totalPackets, 2)
    }

    func testTheStoredAggregationDoesNotCountAnAPRSDestinationAsAStation() throws {
        let store = try makeStore()
        try store.save(micEBeacon(from: "WA0DE-9", destination: "S9RSVQ", radio: handheld, at: 100))
        try store.save(tocallBeacon(from: "AD1CT", destination: "APGRWO", radio: handheld, at: 200))

        let result = try store.aggregateAnalytics(
            in: window, bucket: .hour, calendar: utcCalendar(),
            options: options(selection: .everything))

        XCTAssertEqual(
            result.summary.uniqueStations, 2,
            "two senders, and neither destination is a station")
        XCTAssertTrue(
            result.topDestinations.isEmpty,
            "a latitude and a piece of software are not destinations")
    }

    func testTheStoredAggregationStillCountsANetRomAlias() throws {
        let store = try makeStore()
        try store.save(nodeBeacon(from: "KE0NCQ", destination: "DRLNOD", radio: direwolf, at: 100))

        let result = try store.aggregateAnalytics(
            in: window, bucket: .hour, calendar: utcCalendar(),
            options: options(selection: .everything))

        XCTAssertEqual(
            result.topDestinations.map(\.label), ["DRLNOD"],
            "a node alias rides in a UI frame and is genuinely an address")
    }

    // MARK: - Fixtures

    /// A Mic-E beacon: data type 0x60, destination holding the sender's latitude.
    private func micEBeacon(from: String, destination: String, radio: RadioID, at seconds: TimeInterval) -> Packet {
        packet(from: from, destination: destination, radio: radio, at: seconds,
               info: Data([0x60, 0x70, 0x44, 0x4D]))
    }

    /// An APRS frame whose destination is a tocall naming the sending software.
    private func tocallBeacon(from: String, destination: String, radio: RadioID, at seconds: TimeInterval) -> Packet {
        packet(from: from, destination: destination, radio: radio, at: seconds,
               info: Data([0x21, 0x2F, 0x3A]))
    }

    /// A node identification beacon: a plain text payload, real address.
    private func nodeBeacon(from: String, destination: String, radio: RadioID, at seconds: TimeInterval) -> Packet {
        packet(from: from, destination: destination, radio: radio, at: seconds,
               info: Data("KE0NCQ/R DRL/D".utf8))
    }

    private func packet(from: String, destination: String, radio: RadioID,
                        at seconds: TimeInterval, info: Data) -> Packet {
        let parsedFrom = CallsignParser.parse(from)
        return Packet(
            timestamp: Date(timeIntervalSince1970: seconds),
            from: AX25Address(call: parsedFrom.base, ssid: parsedFrom.ssid ?? 0),
            to: AX25Address(call: destination),
            frameType: .ui,
            control: 0x03,
            pid: 0xF0,
            info: info,
            rawAx25: Data([0x00]),
            radioID: radio)
    }

    private func options(selection: AnalyticsRadioSelection) -> AnalyticsAggregator.Options {
        AnalyticsAggregator.Options(
            includeViaDigipeaters: false,
            histogramBinCount: 8,
            topLimit: 10,
            stationIdentityMode: .ssid,
            radioSelection: selection)
    }

    private func graphOptions() -> NetworkGraphBuilder.Options {
        NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 150,
            stationIdentityMode: .ssid)
    }

    private func makeStore() throws -> SQLitePacketStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLitePacketStore(dbQueue: queue)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }
}
