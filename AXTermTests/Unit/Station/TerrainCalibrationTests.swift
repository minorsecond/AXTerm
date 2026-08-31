import XCTest
@testable import AXTerm

/// Checking the terrain forecast against what the radio has actually done.
///
/// Measured on this operator's own data: of 26 paths with a position and full
/// terrain coverage, the model called every one geometrically obstructed, and
/// several of those stations send frames that arrive here with nothing
/// repeating them — 10,000 of them, in one case. The physics is verified
/// against the Fresnel integral, so the arithmetic is not what is wrong. The
/// inputs are.
final class TerrainCalibrationTests: XCTestCase {

    /// The case this exists for: the page telling an operator not to bother
    /// with a station they are demonstrably receiving.
    func testABlockedPathThatIsHeardAnywayIsContradicted() {
        XCTAssertEqual(
            TerrainCalibration.outcome(severity: .blocking, heardDirectly: true),
            .contradicted)
        XCTAssertEqual(
            TerrainCalibration.outcome(severity: .severe, heardDirectly: true),
            .contradicted)
    }

    /// Below 10 dB the model already says the path works, so a reception
    /// agrees with it. Flagging that as a contradiction would cry wolf on
    /// every working link.
    func testAWorkablePathThatWorksIsNotAContradiction() {
        for severity in [TerrainProfile.Severity.negligible, .noticeable] {
            XCTAssertEqual(
                TerrainCalibration.outcome(severity: severity, heardDirectly: true),
                .consistent, "\(severity)")
        }
    }

    /// Silence is not agreement. A station that never transmits produces
    /// nothing either way, and recording that as confirmation would let the
    /// model mark its own homework.
    func testSilenceIsUntestedRatherThanConfirmed() {
        XCTAssertEqual(
            TerrainCalibration.outcome(severity: .blocking, heardDirectly: false),
            .untested)
        XCTAssertEqual(
            TerrainCalibration.outcome(severity: .severe, heardDirectly: false),
            .untested)
    }

    /// No terrain, no claim to contradict.
    func testAnUnknownPathIsUntestedEvenWhenHeard() {
        XCTAssertEqual(
            TerrainCalibration.outcome(severity: .unknown, heardDirectly: true),
            .untested)
    }

    /// The note has to say the forecast is wrong — not that it is uncertain.
    /// Terrain blocks both directions equally, so a frame that crossed the
    /// ground is a measurement refuting a prediction, and hedging it would
    /// leave the operator weighing a model against their own radio.
    func testTheNoteNamesTheContradictionAndTheLikeliestCause() {
        let note = TerrainCalibration.note(callsign: "K0NTS", directFrames: 10_252)
        XCTAssertTrue(note.contains("K0NTS"))
        XCTAssertTrue(note.contains("10,252 frames"))
        XCTAssertTrue(note.contains("forecast is wrong"))
        // Height before position: it is one number, the operator can find it
        // out, and it is the input the verdict is most sensitive to.
        let height = try? XCTUnwrap(note.range(of: "height"))
        let position = try? XCTUnwrap(note.range(of: "position"))
        XCTAssertLessThan(height!.lowerBound, position!.lowerBound)
    }

    func testTheNoteReadsNaturallyForASingleFrame() {
        let note = TerrainCalibration.note(callsign: "W0TX", directFrames: 1)
        XCTAssertTrue(note.contains("one frame"), note)
        XCTAssertFalse(note.contains("1 frames"), note)
    }
}
