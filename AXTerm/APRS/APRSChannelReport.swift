import Foundation

/// What the channel is doing and what that means for the beacon path.
///
/// Assembled together because neither half stands alone: the load is a number
/// without a decision attached, and the path advice is a rule without evidence
/// until the load is in front of it.
nonisolated struct APRSChannelReport: Equatable, Sendable {
    let load: APRSChannelLoad
    let advice: APRSPathAdvice
    let recommendation: APRSPathRecommendation
    /// The path the beacon actually goes out with, as configured.
    let path: [String]

    static func build(packets: [Packet],
                      repeatHops: [String: Set<Int>],
                      ownFramesHeardBack: Int,
                      path: [String],
                      window: TimeInterval = 900,
                      baud: Int = 1200,
                      now: Date = Date()) -> APRSChannelReport {
        let load = APRSChannelLoadMeter.measure(
            packets: packets, window: window, baud: baud, now: now)
        let advice = APRSPathAdvice.from(
            repeatHops: repeatHops,
            framesObserved: ownFramesHeardBack,
            hopsRequested: APRSPathAdvice.hopsRequested(in: path))
        return APRSChannelReport(
            load: load,
            advice: advice,
            recommendation: APRSPathRecommendation.decide(advice: advice, load: load),
            path: path)
    }

    var pathDescription: String {
        path.isEmpty ? "direct, no digipeaters" : path.joined(separator: ",")
    }
}
