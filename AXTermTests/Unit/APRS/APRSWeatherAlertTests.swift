import XCTest
@testable import AXTerm

/// NWS alerts relayed onto APRS. The rule that matters is that a warning
/// nobody has repeated cannot pass for a current one: the gateway is
/// internet-fed and is the first thing to fail, leaving its last product on
/// the air looking exactly like live weather.
final class APRSWeatherAlertTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Classifying

    func testAGatewayWarningIsAnAlert() throws {
        let alert = try XCTUnwrap(APRSWeatherAlert.classify(
            bulletinID: "1", text: "TORNADO WARNING FOR DOUGLAS CO UNTIL 5PM",
            from: "WXSVR-5", heard: now))
        XCTAssertEqual(alert.severity, .warning)
        XCTAssertEqual(alert.source, "WXSVR-5")
    }

    func testWatchesAndStatementsRankBelowWarnings() {
        func severity(_ text: String) -> APRSWeatherAlert.Severity? {
            APRSWeatherAlert.classify(bulletinID: "1", text: text,
                                      from: "WXSVR", heard: now)?.severity
        }
        XCTAssertEqual(severity("FLASH FLOOD WATCH IN EFFECT"), .watch)
        XCTAssertEqual(severity("SPECIAL WEATHER STATEMENT"), .statement)
        XCTAssertEqual(severity("WINTER STORM WARNING"), .warning)
        XCTAssertTrue(APRSWeatherAlert.Severity.warning > .watch)
        XCTAssertTrue(APRSWeatherAlert.Severity.watch > .statement)
    }

    /// The NWS routinely mentions both when one replaces the other, and the
    /// more serious of the two is the one that governs.
    func testWarningWinsWhenABulletinMentionsBoth() {
        let alert = APRSWeatherAlert.classify(
            bulletinID: "1", text: "TORNADO WARNING REPLACES THE EARLIER WATCH",
            from: "WXSVR", heard: now)
        XCTAssertEqual(alert?.severity, .warning)
    }

    /// Two independent signals are required. Either alone produces false
    /// positives that would train an operator to ignore the banner.
    func testAnOrdinaryBulletinFromAGatewayIsNotAnAlert() {
        XCTAssertNil(APRSWeatherAlert.classify(
            bulletinID: "1", text: "Net tonight at 7pm on the repeater",
            from: "WXSVR", heard: now))
    }

    func testAlertWordingFromANonGatewayIsNotAnAlert() {
        XCTAssertNil(APRSWeatherAlert.classify(
            bulletinID: "1", text: "Club pancake breakfast, rain or shine, flood watch jokes",
            from: "K0EPI-7", heard: now))
    }

    func testGatewayMatchingIsPrefixBased() {
        XCTAssertTrue(APRSWeatherAlert.isGateway("WXSVR-5"))
        XCTAssertTrue(APRSWeatherAlert.isGateway("NWS-DEN"))
        XCTAssertFalse(APRSWeatherAlert.isGateway("K0EPI-7"))
    }

    // MARK: - Staleness, which is the whole point

    func testAFreshAlertIsNotStaleAndSaysWhereItCameFrom() throws {
        let alert = try XCTUnwrap(APRSWeatherAlert.classify(
            bulletinID: "1", text: "TORNADO WARNING", from: "WXSVR", heard: now))
        XCTAssertFalse(alert.isStale(now: now.addingTimeInterval(600)))
        let provenance = alert.provenance(now: now.addingTimeInterval(600))
        XCTAssertTrue(provenance.contains("Relayed by WXSVR"))
        XCTAssertTrue(provenance.contains("internet feed"),
                      "the upstream dependency has to travel with the alert")
    }

    /// The dangerous case: the gateway went off the air and its last warning
    /// is still being repeated by digipeaters.
    func testAnOldAlertIsMarkedPossiblyOutOfDate() throws {
        let alert = try XCTUnwrap(APRSWeatherAlert.classify(
            bulletinID: "1", text: "TORNADO WARNING", from: "WXSVR", heard: now))
        let later = now.addingTimeInterval(APRSWeatherAlert.freshWindow + 60)
        XCTAssertTrue(alert.isStale(now: later))
        XCTAssertTrue(alert.provenance(now: later).contains("possibly out of date"))
    }

    // MARK: - The store

    func testAlertsAreOrderedWorstFirst() {
        var store = APRSWeatherAlertStore()
        store.record(APRSWeatherAlert.classify(
            bulletinID: "1", text: "FLOOD WATCH", from: "WXSVR",
            heard: now)!)
        store.record(APRSWeatherAlert.classify(
            bulletinID: "2", text: "TORNADO WARNING", from: "WXSVR",
            heard: now.addingTimeInterval(-600))!)

        XCTAssertEqual(store.all(now: now).first?.severity, .warning,
                       "a warning outranks a newer watch")
    }

    /// Two gateways relaying the same product is two pieces of evidence that
    /// it is real; collapsing them by id alone would hide that.
    func testTwoGatewaysRelayingTheSameProductAreKeptApart() {
        var store = APRSWeatherAlertStore()
        store.record(APRSWeatherAlert.classify(
            bulletinID: "1", text: "TORNADO WARNING", from: "WXSVR-1", heard: now)!)
        store.record(APRSWeatherAlert.classify(
            bulletinID: "1", text: "TORNADO WARNING", from: "WXSVR-2", heard: now)!)
        XCTAssertEqual(store.all(now: now).count, 2)
    }

    /// A stale alert is kept and listed. "There was a warning and it has gone
    /// quiet" is different information from "there is no warning", and an
    /// operator needs to be able to tell them apart.
    func testStaleAlertsAreKeptButExcludedFromCurrent() {
        var store = APRSWeatherAlertStore()
        store.record(APRSWeatherAlert.classify(
            bulletinID: "1", text: "TORNADO WARNING", from: "WXSVR", heard: now)!)
        let later = now.addingTimeInterval(APRSWeatherAlert.freshWindow + 60)
        XCTAssertEqual(store.all(now: later).count, 1)
        XCTAssertTrue(store.current(now: later).isEmpty)
    }
}
