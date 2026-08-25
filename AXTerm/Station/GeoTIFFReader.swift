import Foundation

/// Reads a float32 GeoTIFF into a plain grid.
///
/// Narrow on purpose. This is not a TIFF library — it reads exactly the shape
/// USGS 3DEP returns: single-band, 32-bit float, uncompressed, one strip or a
/// few. Anything else is refused rather than half-decoded, because a
/// misread elevation grid produces terrain that looks real and is not.
///
/// `ImageIO` could open the file, but it would hand back an image: 32-bit
/// float samples are not pixels, and going through a `CGImage` would quantise
/// elevations to whatever colour space it picked. The bytes are what matter,
/// so the bytes are what this reads.
nonisolated enum GeoTIFFReader {

    enum ReadError: Error, Equatable {
        case notATIFF
        case unsupported(String)
        case sizeMismatch(width: Int, height: Int, expected: Int)
        case truncated

        var explanation: String {
            switch self {
            case .notATIFF:
                "The elevation service did not return a TIFF."
            case .unsupported(let detail):
                "This elevation tile is in a form AXTerm cannot read: \(detail)."
            case .sizeMismatch(let width, let height, let expected):
                "The elevation tile is \(width)×\(height) rather than the \(expected)×\(expected) that was requested."
            case .truncated:
                "The elevation tile ended early — it was probably cut short in transfer."
            }
        }
    }

    // TIFF tag numbers.
    private enum Tag: UInt16 {
        case imageWidth = 256
        case imageLength = 257
        case bitsPerSample = 258
        case compression = 259
        case stripOffsets = 273
        case samplesPerPixel = 277
        case rowsPerStrip = 278
        case stripByteCounts = 279
        case tileWidth = 322
        case tileLength = 323
        case tileOffsets = 324
        case tileByteCounts = 325
        case sampleFormat = 339
    }

    private static let sampleFormatFloat: UInt16 = 3
    private static let compressionNone: UInt16 = 1

    /// Decodes the grid, row-major, north row first — the order TIFF writes
    /// and the order `ElevationStore` expects.
    static func floatGrid(from data: Data, expecting samples: Int) throws -> [Float] {
        guard data.count >= 8 else { throw ReadError.notATIFF }

        let byte0 = data[data.startIndex], byte1 = data[data.startIndex + 1]
        let littleEndian: Bool
        if byte0 == 0x49, byte1 == 0x49 { littleEndian = true }
        else if byte0 == 0x4D, byte1 == 0x4D { littleEndian = false }
        else { throw ReadError.notATIFF }

        guard data.u16(at: 2, littleEndian) == 42 else { throw ReadError.notATIFF }
        let directoryOffset = Int(data.u32(at: 4, littleEndian))
        guard directoryOffset + 2 <= data.count else { throw ReadError.truncated }

        let entryCount = Int(data.u16(at: directoryOffset, littleEndian))
        var fields: [UInt16: [UInt32]] = [:]

        for entry in 0..<entryCount {
            let base = directoryOffset + 2 + entry * 12
            guard base + 12 <= data.count else { throw ReadError.truncated }

            let tag = data.u16(at: base, littleEndian)
            let type = data.u16(at: base + 2, littleEndian)
            let count = Int(data.u32(at: base + 4, littleEndian))
            fields[tag] = try values(in: data, at: base + 8, type: type, count: count,
                                     littleEndian: littleEndian)
        }

        func first(_ tag: Tag, _ fallback: UInt32? = nil) throws -> UInt32 {
            if let value = fields[tag.rawValue]?.first { return value }
            if let fallback { return fallback }
            throw ReadError.unsupported("missing tag \(tag.rawValue)")
        }

        let width = Int(try first(.imageWidth))
        let height = Int(try first(.imageLength))
        guard width == samples, height == samples else {
            throw ReadError.sizeMismatch(width: width, height: height, expected: samples)
        }

        guard try first(.samplesPerPixel, 1) == 1 else {
            throw ReadError.unsupported("more than one band")
        }
        guard try first(.bitsPerSample, 32) == 32 else {
            throw ReadError.unsupported("samples are not 32-bit")
        }
        guard try first(.sampleFormat, UInt32(sampleFormatFloat)) == UInt32(sampleFormatFloat) else {
            throw ReadError.unsupported("samples are not floating point")
        }
        guard try first(.compression, UInt32(compressionNone)) == UInt32(compressionNone) else {
            throw ReadError.unsupported("the tile is compressed")
        }

        // USGS 3DEP returns **tiled** TIFFs, not stripped ones — and the tile
        // is padded to its full size, so a 64×64 request arrives inside a
        // 128×128 tile. Reading that linearly produces a grid that is
        // plausibly shaped and geometrically wrong, which is the worst kind
        // of wrong for terrain. Strips are still handled because other
        // elevation sources use them.
        if let tileOffsets = fields[Tag.tileOffsets.rawValue],
           let tileCounts = fields[Tag.tileByteCounts.rawValue],
           let tileWidth = fields[Tag.tileWidth.rawValue]?.first.map(Int.init),
           let tileHeight = fields[Tag.tileLength.rawValue]?.first.map(Int.init),
           tileWidth > 0, tileHeight > 0 {
            return try assembleTiles(data: data, width: width, height: height,
                                     tileWidth: tileWidth, tileHeight: tileHeight,
                                     offsets: tileOffsets, counts: tileCounts,
                                     littleEndian: littleEndian)
        }

        guard let offsets = fields[Tag.stripOffsets.rawValue],
              let counts = fields[Tag.stripByteCounts.rawValue],
              offsets.count == counts.count, !offsets.isEmpty else {
            throw ReadError.unsupported("neither tile nor strip layout is present")
        }

        var grid = [Float]()
        grid.reserveCapacity(width * height)

        for (offset, byteCount) in zip(offsets, counts) {
            let start = Int(offset), length = Int(byteCount)
            guard start >= 0, start + length <= data.count else { throw ReadError.truncated }
            let strip = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + length))

            for index in stride(from: 0, to: length - 3, by: 4) {
                grid.append(Float(bitPattern: strip.u32(at: index, littleEndian)))
            }
        }

        guard grid.count >= width * height else { throw ReadError.truncated }
        return Array(grid.prefix(width * height))
    }

    /// Reassembles a tiled image into a row-major grid.
    ///
    /// Tiles are laid out left to right then top to bottom, each one
    /// `tileWidth × tileHeight` samples internally, and the last row and
    /// column are **padded** rather than clipped — so the image's own width
    /// and height are what bound the copy, not the tile grid's.
    private static func assembleTiles(data: Data, width: Int, height: Int,
                                      tileWidth: Int, tileHeight: Int,
                                      offsets: [UInt32], counts: [UInt32],
                                      littleEndian: Bool) throws -> [Float] {
        let across = (width + tileWidth - 1) / tileWidth
        let down = (height + tileHeight - 1) / tileHeight
        guard offsets.count >= across * down, counts.count >= across * down else {
            throw ReadError.unsupported("fewer tiles than the image needs")
        }

        var grid = [Float](repeating: ElevationStore.noDataValue, count: width * height)

        for tileRow in 0..<down {
            for tileColumn in 0..<across {
                let index = tileRow * across + tileColumn
                let start = Int(offsets[index]), length = Int(counts[index])
                guard start >= 0, start + length <= data.count else { throw ReadError.truncated }

                for y in 0..<tileHeight {
                    let outputRow = tileRow * tileHeight + y
                    guard outputRow < height else { break }
                    for x in 0..<tileWidth {
                        let outputColumn = tileColumn * tileWidth + x
                        guard outputColumn < width else { break }
                        let byteOffset = (y * tileWidth + x) * 4
                        guard byteOffset + 4 <= length else { throw ReadError.truncated }
                        let bits = data.u32(at: start + byteOffset, littleEndian)
                        grid[outputRow * width + outputColumn] = Float(bitPattern: bits)
                    }
                }
            }
        }

        return grid
    }

    /// A field's values, which live inline when they fit in four bytes and
    /// out of line when they do not — the detail that makes hand-written TIFF
    /// readers subtly wrong.
    private static func values(in data: Data, at offset: Int, type: UInt16,
                               count: Int, littleEndian: Bool) throws -> [UInt32] {
        let width: Int
        switch type {
        case 1, 2, 6, 7: width = 1     // BYTE, ASCII, SBYTE, UNDEFINED
        case 3, 8: width = 2           // SHORT, SSHORT
        case 4, 9, 11: width = 4       // LONG, SLONG, FLOAT
        default: width = 4
        }

        let total = width * count
        let base: Int
        if total <= 4 {
            base = offset
        } else {
            base = Int(data.u32(at: offset, littleEndian))
        }
        guard base >= 0, base + total <= data.count else { throw ReadError.truncated }

        // Only the first few values are ever needed here, but strip offsets
        // can run to hundreds, so all are read.
        return (0..<count).map { index in
            switch width {
            case 1: return UInt32(data[data.startIndex + base + index])
            case 2: return UInt32(data.u16(at: base + index * 2, littleEndian))
            default: return data.u32(at: base + index * 4, littleEndian)
            }
        }
    }
}

// MARK: - Byte reading

private extension Data {
    func u16(at offset: Int, _ littleEndian: Bool) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let start = startIndex + offset
        let raw = self[start..<start + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        return littleEndian ? UInt16(littleEndian: raw) : UInt16(bigEndian: raw)
    }

    func u32(at offset: Int, _ littleEndian: Bool) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let start = startIndex + offset
        let raw = self[start..<start + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return littleEndian ? UInt32(littleEndian: raw) : UInt32(bigEndian: raw)
    }
}
