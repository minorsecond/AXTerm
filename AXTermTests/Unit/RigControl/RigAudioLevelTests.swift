import XCTest
@testable import AXTerm

/// Driving the radio's audio output until the modem sees the right level.
///
/// The demodulator decides from a *ratio* of tone powers, so it is
/// level-independent by design and a quiet signal decodes as well as a loud
/// one — right up until the ends. Too hot and the tones clip, which is
/// distortion no ratio survives; too quiet and the quantiser's own noise
/// becomes a share of the signal. The loop exists for those two ends, not to
/// chase a number in the middle.
final class RigAudioLevelTests: XCTestCase {

    func testALevelInsideTheWindowIsLeftAlone() {
        XCTAssertNil(RigAudioLevel.adjust(current: 120, peakDBFS: -12))
        XCTAssertNil(RigAudioLevel.adjust(current: 120, peakDBFS: -6))
        XCTAssertNil(RigAudioLevel.adjust(current: 120, peakDBFS: -20))
    }

    func testTooHotComesDownAndTooQuietGoesUp() throws {
        let hot = try XCTUnwrap(RigAudioLevel.adjust(current: 200, peakDBFS: -1))
        XCTAssertLessThan(hot, 200)
        let quiet = try XCTUnwrap(RigAudioLevel.adjust(current: 40, peakDBFS: -45))
        XCTAssertGreaterThan(quiet, 40)
    }

    /// A bigger error asks for a bigger step, or a badly-set radio takes all
    /// afternoon to converge.
    func testTheStepFollowsTheError() throws {
        let small = try XCTUnwrap(RigAudioLevel.adjust(current: 128, peakDBFS: -24))
        let large = try XCTUnwrap(RigAudioLevel.adjust(current: 128, peakDBFS: -50))
        XCTAssertGreaterThan(large - 128, small - 128)
    }

    /// The control has ends, and asking for a level outside them is how a loop
    /// spins for ever against a rail.
    func testTheLevelStaysInsideTheControlsRange() throws {
        XCTAssertEqual(RigAudioLevel.adjust(current: 255, peakDBFS: -60), nil,
                       "already at maximum: nothing more to give")
        XCTAssertEqual(RigAudioLevel.adjust(current: 0, peakDBFS: 0), nil,
                       "already at minimum")
        let up = try XCTUnwrap(RigAudioLevel.adjust(current: 250, peakDBFS: -40))
        XCTAssertLessThanOrEqual(up, 255)
    }

    // MARK: - Knowing when the knob is not connected

    /// The IC-705's WLAN audio does not necessarily follow the same control as
    /// its USB audio, and we are in no position to be sure from here. So the
    /// loop checks its own actuator: move the level a long way, and if the
    /// measured peak does not move, say so rather than turning the knob for
    /// ever and reporting success.
    func testAnActuatorThatChangesNothingIsReported() {
        XCTAssertTrue(RigAudioLevel.actuatorIsDead(levelChange: 60, peakChangeDB: 0.2))
        XCTAssertTrue(RigAudioLevel.actuatorIsDead(levelChange: -60, peakChangeDB: -0.1))
        XCTAssertFalse(RigAudioLevel.actuatorIsDead(levelChange: 60, peakChangeDB: 4))
    }

    /// A small nudge proves nothing either way — the audio itself varies from
    /// packet to packet, and calling the control dead on that would be worse
    /// than saying nothing.
    func testASmallNudgeIsNotEvidence() {
        XCTAssertFalse(RigAudioLevel.actuatorIsDead(levelChange: 5, peakChangeDB: 0))
    }

    /// A measurement taken when nothing is on the air is not a measurement.
    func testSilenceIsNotALevel() {
        XCTAssertNil(RigAudioLevel.adjust(current: 128, peakDBFS: -110))
    }
}
