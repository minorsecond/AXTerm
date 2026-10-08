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
    }

    static func prepare(original: Data, name: String, size: PhotoSendSize, format: ImageShrinker.Format,
                        keepsLocation: Bool, byteBudgetOverride: Int? = nil) -> Prepared {
        let pixels = ImageShrinker.pixelSize(of: original) ?? (0, 0)
        let asItIs = Prepared(data: original, name: name, pixelWidth: pixels.width, pixelHeight: pixels.height,
                              isOriginal: true, note: nil)
        guard var options = size.options(format: format, keepsLocation: keepsLocation) else { return asItIs }
        if let byteBudgetOverride { options.byteBudget = byteBudgetOverride }
        switch ImageShrinker.shrink(original, name: name, options: options) {
        case .success(.shrunk(let shrunk)):
            return Prepared(data: shrunk.data, name: shrunk.name, pixelWidth: shrunk.pixelWidth,
                            pixelHeight: shrunk.pixelHeight, isOriginal: false, note: nil)
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
