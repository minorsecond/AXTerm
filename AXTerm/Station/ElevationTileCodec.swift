import Foundation

/// How an elevation tile is stored.
///
/// Tiles were written as raw `Float32`, four bytes a sample, four megabytes a
/// tile. Measured on this operator's own Colorado tiles, which are the worst
/// case because mountains delta badly:
///
///     Float32 1024²           4.00 MB   (what was stored)
///     Int16                   2.00 MB
///     Int16 + deflate         0.93 MB
///     Int16 delta + deflate   0.67 MB   (5.9x)
///
/// Metres as `Int16` is not a compromise. The source is quantised to a metre
/// long before it reaches here, the range covers Denali and Death Valley
/// several times over, and the profile compares terrain against a Fresnel
/// zone tens of metres across. Storing a fractional metre was precision the
/// data never had.
///
/// Row-wise deltas are what make it compress: ground next to ground is nearly
/// the same height, so the differences are small numbers with long runs, and
/// deflate is very good at those. Gradient rather than value.
nonisolated enum ElevationTileCodec {

    /// `AXEL`, so a blob identifies itself. Raw Float32 tiles written before
    /// this existed begin with an elevation in little-endian float, which
    /// cannot collide with these four bytes for any plausible height.
    static let magic: [UInt8] = [0x41, 0x58, 0x45, 0x4C]
    static let version: UInt8 = 1

    /// No data, in Int16. `Int16.min` rather than zero or -9999: it is
    /// outside any real elevation, it survives the delta and back, and
    /// `TerrainProfile` refuses a sample it cannot read rather than treating
    /// a gap as sea level.
    static let noData: Int16 = .min

    enum CodecError: Error, Equatable {
        case notCompressed
        case truncated
        case wrongSampleCount(expected: Int, got: Int)
    }

    /// Encodes a square grid of metres.
    ///
    /// Gaps travel in their own bitmap rather than in the delta stream. A
    /// no-data sample is `Int16.min`, and the step to it from ordinary
    /// ground is about -34,000, which does not fit in an `Int16` delta: it
    /// clamps, and every sample after it in the row decodes wrong. Caught by
    /// the test that says a gap must not spread. The bitmap costs one bit a
    /// sample and compresses to nothing when it is all zeros, which for a
    /// tile of real ground it is.
    static func encode(_ grid: [Float], samples: Int) throws -> Data {
        precondition(grid.count == samples * samples, "grid is not square")

        var gaps = [UInt8](repeating: 0, count: (grid.count + 7) / 8)
        var deltas = [Int16](repeating: 0, count: grid.count)

        for row in 0..<samples {
            // Restarts every row, so a bad sample cannot reach past it.
            var previous: Int32 = 0
            for column in 0..<samples {
                let index = row * samples + column
                let value = quantise(grid[index])
                if value == noData {
                    gaps[index / 8] |= UInt8(1 << (index % 8))
                    // Contributes nothing and does not move the predictor:
                    // the next real sample deltas from the last real one.
                    continue
                }
                deltas[index] = Int16(clamping: Int32(value) - previous)
                previous = Int32(value)
            }
        }

        var payload = Data(gaps)
        deltas.withUnsafeBufferPointer { payload.append(Data(buffer: $0)) }
        guard let compressed = try? (payload as NSData).compressed(using: .zlib) else {
            throw CodecError.notCompressed
        }

        var out = Data(magic)
        out.append(version)
        withUnsafeBytes(of: UInt32(samples).littleEndian) { out.append(contentsOf: $0) }
        out.append(compressed as Data)
        return out
    }

    /// True for a blob in this format. Anything else is a raw Float32 tile
    /// from before it, and still readable.
    static func isEncoded(_ data: Data) -> Bool {
        data.count > header && Array(data.prefix(magic.count)) == magic
    }

    private static let header = 4 + 1 + 4

    static func decode(_ data: Data) throws -> (samples: Int, grid: [Float]) {
        guard isEncoded(data) else { throw CodecError.truncated }
        let samples = Int(data[(magic.count + 1)...].prefix(4).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        })
        guard samples > 0, samples <= 8192 else { throw CodecError.truncated }
        let count = samples * samples
        let maskBytes = (count + 7) / 8

        let body = data.dropFirst(header)
        guard let raw = try? (Data(body) as NSData).decompressed(using: .zlib) else {
            throw CodecError.notCompressed
        }
        let payload = raw as Data
        guard payload.count == maskBytes + count * 2 else {
            throw CodecError.wrongSampleCount(expected: maskBytes + count * 2,
                                              got: payload.count)
        }

        let gaps = [UInt8](payload.prefix(maskBytes))
        let deltas = payload.dropFirst(maskBytes).withUnsafeBytes {
            Array($0.bindMemory(to: Int16.self))
        }

        var grid = [Float](repeating: .nan, count: count)
        for row in 0..<samples {
            var running: Int32 = 0
            for column in 0..<samples {
                let index = row * samples + column
                if gaps[index / 8] & UInt8(1 << (index % 8)) != 0 {
                    grid[index] = .nan
                    continue
                }
                running += Int32(deltas[index])
                grid[index] = Float(Int16(clamping: running))
            }
        }
        return (samples, grid)
    }

    /// Metres, rounded, with anything unreadable becoming the no-data
    /// sentinel. NaN in means NaN out, which is the property TerrainProfile
    /// depends on: a gap read as sea level would turn an unknown ridge into a
    /// clear path, the most dangerous possible way to be wrong.
    static func quantise(_ metres: Float) -> Int16 {
        guard metres.isFinite else { return noData }
        let rounded = metres.rounded()
        guard rounded > Float(Int16.min) + 1, rounded < Float(Int16.max) else {
            return noData
        }
        return Int16(rounded)
    }
}
