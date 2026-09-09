import Foundation

/// Driving the radio's receive audio until the modem sees a usable level.
///
/// The demodulator is level-independent by construction — it compares the two
/// tones' powers, so a quiet signal decodes as well as a loud one. What it
/// cannot survive is either end: clipping distorts the tones, and a level low
/// enough for the quantiser's own noise to matter costs real margin. The loop
/// exists for those two ends and deliberately does nothing in between.
///
/// It also checks its own actuator. The IC-705's WLAN audio does not
/// necessarily follow the same control as its USB audio, and rather than guess
/// from here, the loop moves the level a long way and looks at whether the
/// measured peak moved with it.
nonisolated enum RigAudioLevel {

    /// Where a packet's peak should land. Wide, because the point is to stay
    /// off both rails rather than to hit a number.
    static let target: ClosedRange<Float> = -20 ... -6

    /// Below this there is nothing on the air to measure.
    static let silenceDBFS: Float = -90

    /// The control's own range, as CI-V carries it.
    static let range = 0...255

    /// The next level to try, or nil when there is nothing to do — already in
    /// the window, already against a rail, or nothing being received.
    static func adjust(current: Int, peakDBFS: Float) -> Int? {
        guard peakDBFS > silenceDBFS else { return nil }
        let errorDB: Float
        if peakDBFS > target.upperBound {
            errorDB = peakDBFS - target.upperBound        // positive: too hot
        } else if peakDBFS < target.lowerBound {
            errorDB = peakDBFS - target.lowerBound        // negative: too quiet
        } else {
            return nil
        }
        // The control is not calibrated in dB and its taper is not ours to
        // know, so this is a proportional nudge rather than a computed answer:
        // roughly three counts per dB, which converges in a few passes from
        // anywhere without overshooting into the opposite rail.
        let step = Int((-errorDB * 3).rounded())
        let next = min(range.upperBound, max(range.lowerBound, current + step))
        return next == current ? nil : next
    }

    /// Did moving the control move the audio? A long move that changes nothing
    /// means this is not the knob that feeds the modem.
    static func actuatorIsDead(levelChange: Int, peakChangeDB: Float) -> Bool {
        guard abs(levelChange) >= 40 else { return false }
        return abs(peakChangeDB) < 1
    }
}
