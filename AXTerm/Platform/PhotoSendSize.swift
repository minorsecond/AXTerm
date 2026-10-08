import Foundation

/// The size a photo goes at over packet or Winlink (operator, 2026-10-07).
///
/// A phone photo is several megabytes and a 1200-baud link moves about 60
/// bytes a second, so a photo sent as taken is hours on the air. The
/// operator picks one of these with its airtime and a preview in view.
nonisolated enum PhotoSendSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .original: "Original"
        }
    }

    /// The most the photo may weigh; nil sends it as it is.
    var byteBudget: Int? {
        switch self {
        case .small: 12 * 1024
        case .medium: 25 * 1024
        case .large: 48 * 1024
        case .original: nil
        }
    }

    /// The longest edge tried first.
    var maxLongEdge: Int {
        switch self {
        case .small: 800
        case .medium: 1024
        case .large, .original: 1280
        }
    }

    /// How to shrink to this size; nil for the original.
    func options(format: ImageShrinker.Format, keepsLocation: Bool) -> ImageShrinker.Options? {
        guard let byteBudget else { return nil }
        return ImageShrinker.Options(byteBudget: byteBudget, maxLongEdge: maxLongEdge,
                                     minLongEdge: 240, keepsLocation: keepsLocation, format: format)
    }

    /// Where to start: small on a 1200-baud link, large on a fast one.
    static func suggested(bytesPerSecond: Double?) -> PhotoSendSize {
        (bytesPerSecond ?? AirtimeHint.typicalBytesPerSecond) >= 500 ? .large : .small
    }
}

/// How long a file will take on the air, and on what that is based
/// (operator, 2026-10-07: airtime estimates wherever a file is sent).
nonisolated struct AirtimeHint: Equatable, Sendable {
    var seconds: TimeInterval
    var text: String

    /// A 1200-baud packet link moves about this much file a second once the
    /// frames, acknowledgments and turnarounds are paid for.
    static let typicalBytesPerSecond: Double = 60

    /// A few characters for a footer: "~10 min on air".
    static func short(bytes: Int, measuredBytesPerSecond: Double?) -> String {
        let seconds = Double(bytes) / (measuredBytesPerSecond ?? typicalBytesPerSecond)
        if seconds < 60 { return "<1 min on air" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "~\(minutes) min on air" }
        return "~\(minutes / 60) h \(minutes % 60) min on air"
    }

    static func make(bytes: Int, measuredBytesPerSecond: Double?, peer: String?) -> AirtimeHint? {
        let rate = measuredBytesPerSecond ?? typicalBytesPerSecond
        guard let seconds = TransferAirtimeEstimate.seconds(bytes: bytes, bytesPerSecond: rate) else { return nil }
        let basis = measuredBytesPerSecond != nil
            ? "at the rate of your last transfer" + (peer.map { " with \($0)" } ?? "")
            : "at a typical 1200-baud rate"
        return AirtimeHint(seconds: seconds,
                           text: "\(TransferAirtimeEstimate.describe(seconds)) on the air \(basis)")
    }
}
