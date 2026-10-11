import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// How alike two pictures look, as the structural similarity index (SSIM)
/// of Wang, Bovik, Sheikh and Simoncelli, "Image Quality Assessment: From
/// Error Visibility to Structural Similarity", IEEE Transactions on Image
/// Processing 13(4), 2004.
///
/// 1 is identical; around 0.95 a photo looks the same at a glance, and below
/// about 0.9 blocking, ringing and smearing show. It compares brightness,
/// contrast and local structure in a small window around every pixel, which
/// tracks what people notice far better than the byte or pixel error does.
///
/// Computed on luma only, as the paper does: JPEG and HEIC both keep color at
/// half resolution, and the eye judges detail by brightness. The window is
/// the paper's 11 × 11 Gaussian with σ = 1.5, as two passes of a separable
/// filter through Accelerate, so a 1280-pixel photo takes milliseconds even
/// in a debug build.
nonisolated enum StructuralSimilarity {

    /// An image's brightness at a given size, one 0 to 255 value per pixel.
    struct Luma: Sendable {
        let width: Int
        let height: Int
        let values: [Float]

        /// `image` drawn at `width` × `height` (scaled when it differs from
        /// the image's own size) and reduced to gray.
        init?(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
            let width = width ?? image.width, height = height ?? image.height
            guard width > 0, height > 0 else { return nil }
            var gray = [UInt8](repeating: 0, count: width * height)
            let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            self.values = vDSP.integerToFloatingPoint(gray, floatingPointType: Float.self)
        }

        /// The first image in `data`, decoded and drawn at the given size.
        init?(decoding data: Data, width: Int, height: Int) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            self.init(image, width: width, height: height)
        }
    }

    /// The mean SSIM of `b` against `a`, from -1 to 1 (1 when identical).
    /// Nil when the two are not the same size.
    static func index(_ a: Luma, _ b: Luma) -> Double? {
        guard a.width == b.width, a.height == b.height, !a.values.isEmpty else { return nil }
        // The paper's constants for 8-bit values: (0.01 · 255)² and (0.03 · 255)².
        let c1: Float = 6.5025, c2: Float = 58.5225
        let x = a.values, y = b.values
        let meanX = blur(x, a.width, a.height), meanY = blur(y, a.width, a.height)
        let meanXX = blur(vDSP.square(x), a.width, a.height)
        let meanYY = blur(vDSP.square(y), a.width, a.height)
        let meanXY = blur(vDSP.multiply(x, y), a.width, a.height)

        let meanXMeanY = vDSP.multiply(meanX, meanY)
        let meanXSquared = vDSP.square(meanX), meanYSquared = vDSP.square(meanY)
        let varianceX = vDSP.subtract(meanXX, meanXSquared)
        let varianceY = vDSP.subtract(meanYY, meanYSquared)
        let covariance = vDSP.subtract(meanXY, meanXMeanY)

        // ((2 μx μy + C1)(2 σxy + C2)) / ((μx² + μy² + C1)(σx² + σy² + C2))
        let luminance = vDSP.divide(vDSP.add(c1, vDSP.multiply(2, meanXMeanY)),
                                    vDSP.add(c1, vDSP.add(meanXSquared, meanYSquared)))
        let structure = vDSP.divide(vDSP.add(c2, vDSP.multiply(2, covariance)),
                                    vDSP.add(c2, vDSP.add(varianceX, varianceY)))
        return Double(vDSP.mean(vDSP.multiply(luminance, structure)))
    }

    /// The SSIM of the image in `candidate` against `reference`, with the
    /// candidate scaled to the reference's size first: how it looks when
    /// viewed at that size.
    static func index(of candidate: Data, against reference: Luma) -> Double? {
        guard let luma = Luma(decoding: candidate, width: reference.width, height: reference.height) else {
            return nil
        }
        return index(reference, luma)
    }

    // MARK: - The window

    /// The paper's window: 11 taps of a Gaussian with σ = 1.5, summing to 1.
    static let window: [Float] = {
        let taps = (-5...5).map { Float(exp(-Double($0 * $0) / (2 * 1.5 * 1.5))) }
        let sum = taps.reduce(0, +)
        return taps.map { $0 / sum }
    }()

    /// `values` averaged over the window around each pixel. Pixels past an
    /// edge repeat the edge.
    private static func blur(_ values: [Float], _ width: Int, _ height: Int) -> [Float] {
        var input = values
        var output = [Float](repeating: 0, count: values.count)
        input.withUnsafeMutableBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                var source = vImage_Buffer(data: inputPointer.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width),
                                           rowBytes: width * MemoryLayout<Float>.stride)
                var destination = vImage_Buffer(data: outputPointer.baseAddress,
                                                height: vImagePixelCount(height),
                                                width: vImagePixelCount(width),
                                                rowBytes: width * MemoryLayout<Float>.stride)
                window.withUnsafeBufferPointer { kernel in
                    _ = vImageSepConvolve_PlanarF(&source, &destination, nil, 0, 0,
                                                  kernel.baseAddress!, UInt32(kernel.count),
                                                  kernel.baseAddress!, UInt32(kernel.count),
                                                  0, 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        return output
    }
}
