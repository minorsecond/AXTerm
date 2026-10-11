import Foundation

/// What a photo will be sent as: the bytes that go out, for the preview the
/// operator sees before sending (operator, 2026-10-07). Pure and off the
/// main actor, so the preview can be built while the sheet stays live.
nonisolated enum PhotoSendChoice {
    struct Prepared: Equatable, Sendable {
        var data: Data
        var name: String
        var pixelWidth: Int
        var pixelHeight: Int
        /// The original is going, as asked or because a size was out of reach.
        var isOriginal: Bool
        /// Why the chosen size could not be used, when it could not.
        var note: String?
        /// What it was encoded as; nil when the bytes are the original's.
        var format: ImageShrinker.Format?
        /// The same photo in the other format, for comparison.
        var alternative: Alternative?

        /// "11 KB as HEIC (JPEG would be 21 KB)", with the other format's
        /// pixel size when the budget made it smaller.
        var formatComparison: String? {
            guard let format, let alternative else { return nil }
            let smaller = (alternative.pixelWidth, alternative.pixelHeight) != (pixelWidth, pixelHeight)
                ? " at \(alternative.pixelWidth) × \(alternative.pixelHeight) px" : ""
            return "\(ByteCount.string(data.count)) as \(format.title) "
                + "(\(alternative.format.title) would be \(ByteCount.string(alternative.byteCount))\(smaller))"
        }
    }

    struct Alternative: Equatable, Sendable {
        var format: ImageShrinker.Format
        var byteCount: Int
        var pixelWidth: Int
        var pixelHeight: Int
    }

    /// `comparesFormats` also encodes the photo in the other format, at the
    /// same size and look, for the preview's comparison.
    static func prepare(original: Data, name: String, size: PhotoSendSize, format: ImageShrinker.Format,
                        keepsLocation: Bool, byteBudgetOverride: Int? = nil,
                        comparesFormats: Bool = false) -> Prepared {
        let pixels = ImageShrinker.pixelSize(of: original) ?? (0, 0)
        let asItIs = Prepared(data: original, name: name, pixelWidth: pixels.width, pixelHeight: pixels.height,
                              isOriginal: true, note: nil)
        guard var options = size.options(format: format, keepsLocation: keepsLocation) else { return asItIs }
        if let byteBudgetOverride { options.byteBudget = byteBudgetOverride }
        switch ImageShrinker.shrink(original, name: name, options: options) {
        case .success(.shrunk(let shrunk)):
            var alternative: Alternative?
            if comparesFormats {
                var other = options
                other.format = format == .jpeg ? .heic : .jpeg
                if case .success(.shrunk(let otherShrunk)) = ImageShrinker.shrink(original, name: name,
                                                                                 options: other) {
                    alternative = Alternative(format: other.format, byteCount: otherShrunk.data.count,
                                              pixelWidth: otherShrunk.pixelWidth,
                                              pixelHeight: otherShrunk.pixelHeight)
                }
            }
            return Prepared(data: shrunk.data, name: shrunk.name, pixelWidth: shrunk.pixelWidth,
                            pixelHeight: shrunk.pixelHeight, isOriginal: false, note: nil,
                            format: format, alternative: alternative)
        case .success(.locationRemoved(let data)):
            return Prepared(data: data, name: name, pixelWidth: pixels.width, pixelHeight: pixels.height,
                            isOriginal: false, note: nil)
        case .success(.unchanged):
            return asItIs
        case .failure(.cannotMeetBudget(let smallest)):
            var kept = asItIs
            kept.note = "It cannot be made that small; the smallest it goes is "
                + ByteCount.string(Int64(smallest)) + ". Pick a bigger size."
            return kept
        case .failure(.animated):
            var kept = asItIs
            kept.note = "An animated image is sent as it is; shrinking would keep only its first frame."
            return kept
        case .failure:
            var kept = asItIs
            kept.note = "This image could not be shrunk, so it would go as it is."
            return kept
        }
    }
}
