import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Photo-like test images, made in memory.
///
/// Smooth color fields with a little per-pixel grain, so JPEG and HEIC
/// compress them roughly the way they compress a real photo. Pure noise
/// would never shrink and a flat color would always shrink, and neither says
/// anything about how the shrinker treats a picture off a phone.
enum SyntheticPhoto {

    static func image(width: Int, height: Int, seed: UInt32 = 1) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        var state = seed | 1
        for y in 0..<height {
            for x in 0..<width {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                let grain = Int(state % 24) - 12
                let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
                let r = 128 + 100 * sin(fx * 7 + Double(seed)) + Double(grain)
                let g = 128 + 90 * cos(fy * 5 + fx * 3) + Double(grain)
                let b = 128 + 80 * sin((fx + fy) * 11) + Double(grain)
                let i = y * bytesPerRow + x * 4
                pixels[i] = UInt8(max(0, min(255, r)))
                pixels[i + 1] = UInt8(max(0, min(255, g)))
                pixels[i + 2] = UInt8(max(0, min(255, b)))
                pixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// A GPS dictionary for somewhere in Colorado.
    static let gps: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: 39.7392,
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 104.9903,
        kCGImagePropertyGPSLongitudeRef: "W",
    ]

    /// Encoded bytes, or nil when this machine cannot write `type` (HEIC
    /// needs a hardware encoder).
    static func data(width: Int, height: Int, type: UTType = .jpeg, quality: Double = 0.92,
                     seed: UInt32 = 1, gps: [CFString: Any]? = nil, orientation: Int? = nil) -> Data? {
        encode(image(width: width, height: height, seed: seed), type: type, quality: quality,
               gps: gps, orientation: orientation)
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double = 0.92,
                       gps: [CFString: Any]? = nil, orientation: Int? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// A two-frame animated GIF.
    static func animatedGIF(width: Int, height: Int) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(destination, image(width: width, height: height, seed: 1), nil)
        CGImageDestinationAddImage(destination, image(width: width, height: height, seed: 2), nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func typeIdentifier(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }
}
