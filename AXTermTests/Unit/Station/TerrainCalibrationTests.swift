import XCTest
@testable import AXTerm

/// Checking the terrain forecast against what the radio has actually done.
///
/// The bar is a completed connection over a path with no digipeater in it.
/// Anything weaker cannot outrank a terrain verdict, and claiming otherwise
/// on the strength of a beacon we happened to hear would make the page less
/// trustworthy, not more.
final class TerrainCalibrationTests: XCTestCase {

    private let when = Date(timeIntervalSince1970: 1_756_000_000)

    /// The case this exists for: the page rating a path badly that this
    /// station has already worked.
    func testAConnectionOverABadlyRatedPathContradictsIt() {
        for severity in [TerrainProfile.Severity.severe, .blocking] {
            XCTAssertEqual(
                TerrainCalibration.outcome(severity: severity,
                                           hasCompletedDirectConnection: true),
                .contradicted, "\(severity)")
        }
    }

    /// Below 10 dB the model already says the path works, so a connection
    /// agrees with it. Flagging that would cry wolf on every good link.
    func testAConnectionOverAWorkablePathAgreesWithTheModel() {
        for severity in [TerrainProfile.Severity.negligible, .noticeable] {
            XCTAssertEqual(
                TerrainCalibration.outcome(severity: severity,
                                           hasCompletedDirectConnection: true),
                .consistent, "\(severity)")
        }
    }

    /// No connection is not agreement. An untried path produces silence
    /// either way, and counting that as confirmation would let the model mark
    /// its own homework.
    func testNoConnectionIsUntestedRatherThanConfirmed() {
        XCTAssertEqual(
            TerrainCalibration.outcome(severity: .blocking,
                                       hasCompletedDirectConnection: false),
            .untested)
    }

    func testNoTerrainMeansNoClaimToContradict() {
        XCTAssertEqual(
            TerrainCalibration.outcome(severity: .unknown,
                                       hasCompletedDirectConnection: true),
            .untested)
    }

    /// The note is a fact about the connection, not a verdict on the chart.
    /// The operator can see the chart. What they cannot see is that their own
    /// station has already worked this path.
    func testTheNoteStatesTheConnectionAndNamesTheInputToFix() {
        let note = TerrainCalibration.note(callsign: "W0TX", lastConnected: when)
        XCTAssertTrue(note.contains("W0TX"))
        XCTAssertTrue(note.contains("connected directly"))
        XCTAssertTrue(note.contains("antenna height"))
    }

    /// Quiet, not accusatory. Shouting that our own forecast is wrong is a
    /// strange way to be trusted, and the operator asked for a line, not an
    /// alarm.
    func testTheNoteDoesNotShout() {
        let note = TerrainCalibration.note(callsign: "W0TX", lastConnected: when)
        for shout in ["wrong", "Warning", "!", "error", "failed"] {
            XCTAssertFalse(note.contains(shout), "note should not say \"\(shout)\": \(note)")
        }
        XCTAssertLessThan(note.count, 220, "one line, not a paragraph")
    }

    /// A date is worth having when there is one, and the sentence still has
    /// to read when there is not.
    func testTheDateIsOptional() {
        XCTAssertTrue(
            TerrainCalibration.note(callsign: "W0TX", lastConnected: when).contains(" on "))
        let undated = TerrainCalibration.note(callsign: "W0TX", lastConnected: nil)
        XCTAssertTrue(undated.contains("over this path."), undated)
    }
}
