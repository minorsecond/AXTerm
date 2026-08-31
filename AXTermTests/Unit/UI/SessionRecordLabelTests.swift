import XCTest
@testable import AXTerm

/// Naming the rows in the Sessions picker.
///
/// Records are keyed by *transport* — `ax25|DRLBBS` and `netrom|DRLBBS|auto`
/// are different sessions with different stats — but the label was the
/// destination alone, so two genuinely different ways of reaching one station
/// rendered as two identical rows and the operator could not tell them apart
/// or say which one they were about to switch to (2026-08-31).
final class SessionRecordLabelTests: XCTestCase {

    private func item(_ id: String, _ destination: String,
                      _ transport: SessionRecordLabel.Transport,
                      via: [String] = [], relay: String? = nil,
                      status: String = "Connected") -> SessionRecordLabel.Item {
        .init(id: id, destination: destination, transport: transport,
              via: via, relayDestination: relay, statusText: status)
    }

    /// The common case: nothing to disambiguate, so say nothing extra. A
    /// picker full of qualifiers is harder to read than one without.
    func testAUniqueDestinationIsJustItsName() {
        let labels = SessionRecordLabel.labels(for: [
            item("ax25|DRLBBS", "DRLBBS", .ax25),
            item("ax25|KB5YZB-1", "KB5YZB-1", .ax25),
        ])
        XCTAssertEqual(labels["ax25|DRLBBS"], "DRLBBS")
        XCTAssertEqual(labels["ax25|KB5YZB-1"], "KB5YZB-1")
    }

    /// The reported bug: one station reached two ways, two identical rows.
    func testTwoTransportsToOneStationAreToldApart() {
        let labels = SessionRecordLabel.labels(for: [
            item("ax25|DRLBBS", "DRLBBS", .ax25),
            item("netrom|DRLBBS|auto", "DRLBBS", .netrom),
        ])
        XCTAssertEqual(labels["ax25|DRLBBS"], "DRLBBS · AX.25")
        XCTAssertEqual(labels["netrom|DRLBBS|auto"], "DRLBBS · NET/ROM")
    }

    /// Same transport, different path, is also a different session.
    func testTheDigipeaterPathDisambiguates() {
        let labels = SessionRecordLabel.labels(for: [
            item("ax25|WD0HDR-1", "WD0HDR-1", .ax25),
            item("ax25digi|WD0HDR-1|EATON", "WD0HDR-1", .ax25ViaDigi, via: ["EATON"]),
        ])
        XCTAssertEqual(labels["ax25|WD0HDR-1"], "WD0HDR-1 · AX.25")
        XCTAssertEqual(labels["ax25digi|WD0HDR-1|EATON"], "WD0HDR-1 · via EATON")
    }

    /// A closed session left in the list looks exactly like the live one it
    /// was replaced by. Status is the distinguishing fact there, and the
    /// operator needs it before they pick the dead one.
    func testAClosedSessionSaysSo() {
        let labels = SessionRecordLabel.labels(for: [
            item("netrom|BBSCBH|auto", "BBSCBH", .netrom, status: "Disconnected"),
            item("ax25|BBSCBH", "BBSCBH", .ax25, status: "Connected"),
        ])
        XCTAssertEqual(labels["netrom|BBSCBH|auto"], "BBSCBH · NET/ROM (disconnected)")
        XCTAssertEqual(labels["ax25|BBSCBH"], "BBSCBH · AX.25")
    }

    /// A relay names both ends, and that alone already distinguishes it.
    func testARelayKeepsItsChainInTheLabel() {
        let labels = SessionRecordLabel.labels(for: [
            item("ax25|DRLNOD", "DRLNOD", .ax25, relay: "BBSCBH"),
            item("ax25|DRLBBS", "DRLBBS", .ax25),
        ])
        XCTAssertEqual(labels["ax25|DRLNOD"], "DRLNOD → BBSCBH")
    }

    /// Two relays through the same node to different destinations must not
    /// collapse — the far end is the whole point of the row.
    func testTwoRelaysThroughOneNodeStayDistinct() {
        let labels = SessionRecordLabel.labels(for: [
            item("ax25|DRLNOD", "DRLNOD", .ax25, relay: "BBSCBH"),
            item("netrom|DRLNOD|auto", "DRLNOD", .netrom, relay: "COSCO"),
        ])
        XCTAssertEqual(labels["ax25|DRLNOD"], "DRLNOD → BBSCBH")
        XCTAssertEqual(labels["netrom|DRLNOD|auto"], "DRLNOD → COSCO")
    }

    /// Qualifying is driven by collision, not by transport: an identical
    /// destination *and* transport (a circuit record mirrored beside a
    /// connect record) still has to be separable, and status is the last
    /// thing left to say.
    func testAnUnresolvableCollisionStillDiffersByStatus() {
        let labels = SessionRecordLabel.labels(for: [
            item("netrom|COSCO|auto", "COSCO", .netrom, status: "Connected"),
            item("circuit|17", "COSCO", .netrom, status: "Disconnected"),
        ])
        XCTAssertNotEqual(labels["netrom|COSCO|auto"], labels["circuit|17"])
    }

    /// Empty in, empty out — the picker renders "All Traffic" alone.
    func testNoRecordsProducesNoLabels() {
        XCTAssertTrue(SessionRecordLabel.labels(for: []).isEmpty)
    }
}
