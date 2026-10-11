import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes a photo small enough to send over a radio link.
///
/// A phone photo is 2 to 5 MB. Winlink's whole message budget is 120 KB, and
/// at 1200 baud even that is a quarter of an hour on the air, so a photo
/// attached as taken can never be sent at all.
///
/// Every byte is airtime, so the aim is the fewest bytes that still look
/// right, with the byte budget as a cap (2026-10-11, after "HEIC, smaller"
/// came out bigger than JPEG under a budget-filling search):
///
/// 1. The long edge is `maxLongEdge`, never more than the photo's own.
/// 2. At that size, a binary search on the encoder's quality setting finds
///    the lowest one whose result still has a structural similarity of
///    `targetSimilarity` to the scaled original (`StructuralSimilarity`).
///    That is the cheapest encoding that looks right, and it is usually well
///    under the budget. JPEG and HEIC both meet the same look, so each format
///    costs what it needs and HEIC comes out smaller.
/// 3. Only when that does not fit the budget does the picture get smaller.
///    At each step down the ladder it takes the highest quality that fits,
///    upscales the result back to `maxLongEdge` and scores it there, which
///    is how it will be viewed, and keeps the step that looks best. Too large
///    a picture at that budget is blocky, too small is blurry, and the best
///    lies between (the same trade a video encoder makes when it chooses a
///    resolution for a bitrate).
///
/// It works on bytes with ImageIO only, with no AppKit or UIKit, so it runs
/// the same on the Mac, the iPhone and the iPad, runs off the main actor, and
/// can be tested without a screen. The packet transfer path can use it too.
///
/// What it never does is hand back something worse than the operator asked
/// for without saying so. A budget it cannot meet at the smallest size it is
/// willing to make is reported as a failure, and the caller keeps the
/// original. A 60-pixel thumbnail that technically fits is not a photo.
nonisolated enum ImageShrinker {

    /// How to shrink.
    struct Options: Equatable, Sendable {
        /// The most the result may weigh, in bytes.
        var byteBudget: Int
        /// The longest edge tried first, in pixels. Nothing a radio link can
        /// carry needs more than this.
        var maxLongEdge: Int = 1600
        /// The smallest long edge worth sending. Below this the photo stops
        /// being useful and shrinking is reported as failed instead.
        var minLongEdge: Int = 320
        /// Keep the photo's GPS position in the result. Off by default: a
        /// photo taken at home tells every station that copies the message
        /// where home is, and packet radio is readable by anyone listening.
        var keepsLocation: Bool = false
        /// What to write. JPEG opens everywhere; HEIC looks the same in less
        /// airtime but wants an Apple device or a recent viewer.
        var format: Format = .jpeg
        /// How alike the result must look to the original at `maxLongEdge`,
        /// as structural similarity (1 is identical).
        var targetSimilarity: Double = ImageShrinker.targetSimilarity

        init(byteBudget: Int, maxLongEdge: Int = 1600, minLongEdge: Int = 320,
             keepsLocation: Bool = false, format: Format = .jpeg,
             targetSimilarity: Double = ImageShrinker.targetSimilarity) {
            self.byteBudget = byteBudget
            self.maxLongEdge = maxLongEdge
            self.minLongEdge = minLongEdge
            self.keepsLocation = keepsLocation
            self.format = format
            self.targetSimilarity = targetSimilarity
        }
    }

    enum Format: String, CaseIterable, Equatable, Sendable {
        case jpeg
        case heic

        var type: UTType { self == .jpeg ? .jpeg : .heic }
        var title: String { self == .jpeg ? "JPEG" : "HEIC" }
        var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
    }

    /// A photo that now fits.
    struct Shrunk: Equatable, Sendable {
        var data: Data
        /// The original name with its extension changed to the format's.
        var name: String
        var pixelWidth: Int
        var pixelHeight: Int
        /// The encoder's quality setting, 0 to 1.
        var quality: Double
        /// How alike it looks to the original viewed at `maxLongEdge`, as
        /// structural similarity.
        var similarity: Double
        var originalByteCount: Int
    }

    enum Outcome: Equatable, Sendable {
        /// Already within the budget. The bytes are left exactly as they
        /// were: re-encoding a JPEG that fits only loses detail.
        case unchanged
        /// Already within the budget, with its GPS position taken out and
        /// the pixels copied untouched.
        case locationRemoved(Data)
        case shrunk(Shrunk)
    }

    enum Failure: Error, Equatable, Sendable {
        /// ImageIO could not read the bytes as an image.
        case notAnImage
        /// Animated images would lose every frame but the first. Sent as they
        /// are or not at all.
        case animated
        /// Even the smallest, roughest version was bigger than the budget.
        /// Carries that smallest size so the caller can say how far off it was.
        case cannotMeetBudget(smallestBytes: Int)
        /// ImageIO refused to write the image.
        case encodeFailed
    }

    /// Long edges tried when the budget is too small for the look, largest
    /// first, each a step down from the last. Fixed steps rather than a
    /// search so the same photo always lands on the same size.
    static func edgeLadder(startingAt longEdge: Int, maxLongEdge: Int, minLongEdge: Int) -> [Int] {
        var edge = min(longEdge, maxLongEdge)
        var ladder: [Int] = []
        while edge > minLongEdge {
            ladder.append(edge)
            edge = Int((Double(edge) * 0.8).rounded())
        }
        ladder.append(min(longEdge, minLongEdge))
        return ladder
    }

    /// The look aimed for: at 0.95 structural similarity a photo looks the
    /// same as the original at a glance, with fine texture a little softer.
    static let targetSimilarity = 0.95

    /// The range of encoder quality settings searched. Below 0.05 both
    /// encoders fall apart; above 0.95 they spend bytes on nothing visible.
    static let qualityRange: ClosedRange<Double> = 0.05...0.95

    /// Halvings of the quality range per search: 0.9 / 2⁷, about 0.007, finer
    /// than either encoder's own steps.
    static let searchSteps = 7

    /// True when these bytes are an image ImageIO can read and re-encode.
    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let uti = UTType(type) else { return false }
        return uti.conforms(to: .image) && CGImageSourceGetCount(source) > 0
    }

    /// True when a file with this name is an image by its extension. Used
    /// before the bytes are read, to decide what to offer.
    static func isImage(named name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// Pixel size with the photo's orientation applied, so a portrait photo
    /// reads as portrait.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // EXIF orientations 5 to 8 rotate the image a quarter turn.
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// True when the image carries a GPS position.
    static func containsLocation(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return false }
        return !gps.isEmpty
    }

    /// The same image with its GPS position removed and nothing else
    /// changed: the compressed pixels are copied, not decoded and encoded
    /// again, so there is no loss of quality. Nil when ImageIO cannot do
    /// that for this format.
    static func removingLocation(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            return nil
        }
        let result = output as Data
        return containsLocation(result) ? nil : result
    }

    /// `name` with its extension replaced by `.jpg`.
    static func jpegName(for name: String) -> String {
        fileName(for: name, format: .jpeg)
    }

    /// `name` with its extension replaced by the format's.
    static func fileName(for name: String, format: Format) -> String {
        let stem = (name as NSString).deletingPathExtension
        return (stem.isEmpty ? "Photo" : stem) + "." + format.fileExtension
    }

    /// The fewest bytes that look right, within `options.byteBudget`.
    static func shrink(_ data: Data, name: String, options: Options) -> Result<Outcome, Failure> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source) as String?,
              let type = UTType(typeID), type.conforms(to: .image),
              let size = pixelSize(of: data) else {
            return .failure(.notAnImage)
        }
        if CGImageSourceGetCount(source) > 1 && type.conforms(to: .gif) {
            return .failure(.animated)
        }

        let longEdge = max(size.width, size.height)
        if data.count <= options.byteBudget {
            if options.keepsLocation || !containsLocation(data) {
                return .success(.unchanged)
            }
            if let stripped = removingLocation(from: data), stripped.count <= options.byteBudget {
                return .success(.locationRemoved(stripped))
            }
            // A format ImageIO cannot copy without decoding falls through to
            // a re-encode, which drops the position as a side effect.
        }

        let location = options.keepsLocation ? gpsDictionary(of: source) : nil
        let viewEdge = min(longEdge, options.maxLongEdge)
        guard let reference = thumbnail(source, longEdge: viewEdge),
              let referenceLuma = StructuralSimilarity.Luma(reference) else {
            return .failure(.encodeFailed)
        }
        let encoder = Encoder(format: options.format, gps: location, reference: referenceLuma)
        let finish = { (candidate: Candidate) -> Result<Outcome, Failure> in
            .success(.shrunk(Shrunk(
                data: candidate.data, name: fileName(for: name, format: options.format),
                pixelWidth: candidate.pixelWidth, pixelHeight: candidate.pixelHeight,
                quality: candidate.quality, similarity: candidate.similarity,
                originalByteCount: data.count)))
        }

        // The cheapest encoding that looks right at the chosen size.
        guard let looksRight = encoder.cheapest(reference, lookingAtLeast: options.targetSimilarity) else {
            return .failure(.encodeFailed)
        }
        if looksRight.data.count <= options.byteBudget { return finish(looksRight) }

        // The budget is the limit: the best look it buys, at whichever size
        // looks best when viewed at `viewEdge`.
        var best: Candidate?
        var smallest = looksRight.data.count
        for edge in edgeLadder(startingAt: longEdge, maxLongEdge: options.maxLongEdge,
                               minLongEdge: options.minLongEdge) {
            guard let image = edge == viewEdge ? reference : scaled(reference, longEdge: edge) else {
                return .failure(.encodeFailed)
            }
            let fitted = encoder.best(image, within: options.byteBudget)
            smallest = min(smallest, fitted.smallestBytes)
            guard let candidate = fitted.candidate else { continue }
            // Past the best size the picture only gets blurrier.
            if let best, candidate.similarity <= best.similarity { break }
            best = candidate
        }
        guard let best else { return .failure(.cannotMeetBudget(smallestBytes: smallest)) }
        return finish(best)
    }

    // MARK: - Searching

    /// One encoding of one picture.
    private struct Candidate {
        var data: Data
        var pixelWidth: Int
        var pixelHeight: Int
        var quality: Double
        /// Against the reference, viewed at the reference's size.
        var similarity: Double
    }

    /// Encodes pictures in one format and scores them against the reference.
    private struct Encoder {
        let format: Format
        let gps: [CFString: Any]?
        let reference: StructuralSimilarity.Luma

        func encode(_ image: CGImage, quality: Double) -> Data? {
            ImageShrinker.encode(image, as: format, quality: quality, gps: gps)
        }

        func candidate(_ image: CGImage, quality: Double, data: Data) -> Candidate? {
            guard let similarity = StructuralSimilarity.index(of: data, against: reference) else { return nil }
            return Candidate(data: data, pixelWidth: image.width, pixelHeight: image.height,
                             quality: quality, similarity: similarity)
        }

        func attempt(_ image: CGImage, quality: Double) -> Candidate? {
            encode(image, quality: quality).flatMap { candidate(image, quality: quality, data: $0) }
        }

        /// The lowest quality whose result looks at least `target` alike,
        /// by binary search. Bytes grow with quality, so that is the fewest
        /// bytes; the smallest passing result seen is kept in case an
        /// encoder's steps are not quite in order. When even the top of the
        /// range falls short, the top is the best it can look.
        func cheapest(_ image: CGImage, lookingAtLeast target: Double) -> Candidate? {
            var low = qualityRange.lowerBound, high = qualityRange.upperBound
            guard var best = attempt(image, quality: high) else { return nil }
            guard best.similarity >= target else { return best }
            for _ in 0..<searchSteps {
                let middle = (low + high) / 2
                guard let tried = attempt(image, quality: middle) else { return nil }
                if tried.similarity >= target {
                    if tried.data.count <= best.data.count { best = tried }
                    high = middle
                } else {
                    low = middle
                }
            }
            return best
        }

        /// The highest quality whose result fits `budget`, by binary search,
        /// scored against the reference; nil when even the lowest does not
        /// fit. Also the size of that lowest, for the failure report.
        func best(_ image: CGImage, within budget: Int) -> (candidate: Candidate?, smallestBytes: Int) {
            var low = qualityRange.lowerBound, high = qualityRange.upperBound
            guard let lowest = encode(image, quality: low) else { return (nil, Int.max) }
            guard lowest.count <= budget else { return (nil, lowest.count) }
            var fit = (quality: low, data: lowest)
            if let highest = encode(image, quality: high), highest.count <= budget {
                fit = (high, highest)
            } else {
                for _ in 0..<searchSteps {
                    let middle = (low + high) / 2
                    guard let tried = encode(image, quality: middle) else { break }
                    if tried.count <= budget {
                        fit = (middle, tried)
                        low = middle
                    } else {
                        high = middle
                    }
                }
            }
            return (candidate(image, quality: fit.quality, data: fit.data), lowest.count)
        }
    }

    // MARK: - ImageIO

    private static func gpsDictionary(of source: CGImageSource) -> [CFString: Any]? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    }

    /// `image` drawn smaller, `longEdge` on its long side.
    private static func scaled(_ image: CGImage, longEdge: Int) -> CGImage? {
        let scale = Double(longEdge) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A decoded copy no longer than `longEdge` on its long side, with the
    /// orientation baked into the pixels, so the result needs no orientation
    /// tag and displays upright everywhere.
    private static func thumbnail(_ source: CGImageSource, longEdge: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A JPEG or HEIC carrying no metadata except, when asked for, the GPS
    /// position. The camera's EXIF and maker notes can be several kilobytes,
    /// and every one of them costs airtime. The colors are converted to sRGB,
    /// which every viewer assumes, with its compact profile in place of a
    /// phone's Display P3 one.
    private static func encode(_ image: CGImage, as format: Format, quality: Double,
                               gps: [CFString: Any]?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, format.type.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationOptimizeColorForSharing: true,
        ]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
