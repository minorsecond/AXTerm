import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes a photo small enough to send over a radio link.
///
/// A phone photo is 2 to 5 MB. Winlink's whole message budget is 120 KB, and
/// at 1200 baud even that is a quarter of an hour on the air, so a photo
/// attached as taken can never be sent at all. This turns it into a JPEG
/// that fits a byte budget: it scales the long edge down and steps the JPEG
/// quality down until the result fits, trying the larger sizes first so
/// detail goes before resolution does.
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

        init(byteBudget: Int, maxLongEdge: Int = 1600, minLongEdge: Int = 320,
             keepsLocation: Bool = false) {
            self.byteBudget = byteBudget
            self.maxLongEdge = maxLongEdge
            self.minLongEdge = minLongEdge
            self.keepsLocation = keepsLocation
        }
    }

    /// A photo that now fits.
    struct Shrunk: Equatable, Sendable {
        var data: Data
        /// The original name with its extension changed to `.jpg`.
        var name: String
        var pixelWidth: Int
        var pixelHeight: Int
        /// The JPEG quality that got it under the budget, 0 to 1.
        var quality: Double
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
        /// ImageIO refused to write a JPEG.
        case encodeFailed
    }

    /// Long edges tried, largest first, each a step down from the last.
    /// Fixed steps rather than a search so the same photo always lands on the
    /// same size.
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

    /// Qualities tried at each size. Low qualities are only used once the
    /// size ladder has run out, because a small sharp photo beats a large
    /// blocky one.
    static let qualities: [Double] = [0.75, 0.6, 0.45]
    static let lastResortQualities: [Double] = [0.35, 0.25]

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
        let stem = (name as NSString).deletingPathExtension
        return (stem.isEmpty ? "Photo" : stem) + ".jpg"
    }

    /// Shrinks `data` to fit `options.byteBudget`.
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
        let ladder = edgeLadder(startingAt: longEdge,
                                maxLongEdge: options.maxLongEdge,
                                minLongEdge: options.minLongEdge)
        var smallest = Int.max
        for (index, edge) in ladder.enumerated() {
            guard let image = thumbnail(source, longEdge: edge) else { return .failure(.encodeFailed) }
            let isLast = index == ladder.count - 1
            for quality in qualities + (isLast ? lastResortQualities : []) {
                guard let jpeg = encodeJPEG(image, quality: quality, gps: location) else {
                    return .failure(.encodeFailed)
                }
                smallest = min(smallest, jpeg.count)
                if jpeg.count <= options.byteBudget {
                    return .success(.shrunk(Shrunk(
                        data: jpeg, name: jpegName(for: name),
                        pixelWidth: image.width, pixelHeight: image.height,
                        quality: quality, originalByteCount: data.count)))
                }
            }
        }
        return .failure(.cannotMeetBudget(smallestBytes: smallest))
    }

    // MARK: - ImageIO

    private static func gpsDictionary(of source: CGImageSource) -> [CFString: Any]? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyGPSDictionary] as? [CFString: Any]
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

    /// A baseline JPEG carrying no metadata except, when asked for, the GPS
    /// position. The camera's EXIF and maker notes can be several kilobytes,
    /// and every one of them costs airtime.
    private static func encodeJPEG(_ image: CGImage, quality: Double, gps: [CFString: Any]?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
