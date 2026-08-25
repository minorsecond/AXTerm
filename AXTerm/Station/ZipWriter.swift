import Foundation

/// Builds a zip archive.
///
/// A shapefile is four files that only work together, so exporting one means
/// producing an archive. Foundation has no zip writer, and the format's
/// stored (uncompressed) variant is small enough to write directly — about
/// eighty lines — which is cheaper than a dependency and avoids shipping a
/// compression library to bundle four files nobody will decompress twice.
///
/// Stored rather than deflated on purpose. The `.shp` is mostly
/// double-precision coordinates, which deflate poorly, and anything actually
/// going over the air should be GeoJSON — which is text, compresses well, and
/// is a tenth the size. See `Docs/MapOverlays.md`.
nonisolated enum ZipWriter {

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfDirectorySignature: UInt32 = 0x0605_4B50
    /// "Stored" — no compression.
    private static let methodStored: UInt16 = 0

    struct Entry {
        let name: String
        let data: Data
    }

    static func archive(files: [(name: String, data: Data)]) -> Data {
        var output = Data()
        var directory = Data()
        var offsets: [Int] = []

        for file in files {
            offsets.append(output.count)
            let name = Data(file.name.utf8)
            let crc = crc32(file.data)

            output.append(little: localHeaderSignature)
            output.append(little: UInt16(20))            // version needed
            output.append(little: UInt16(0))             // flags
            output.append(little: methodStored)
            output.append(little: UInt16(0))             // mod time
            output.append(little: UInt16(0))             // mod date
            output.append(little: crc)
            output.append(little: UInt32(file.data.count))
            output.append(little: UInt32(file.data.count))
            output.append(little: UInt16(name.count))
            output.append(little: UInt16(0))             // extra field length
            output.append(name)
            output.append(file.data)
        }

        for (index, file) in files.enumerated() {
            let name = Data(file.name.utf8)
            directory.append(little: centralHeaderSignature)
            directory.append(little: UInt16(20))         // version made by
            directory.append(little: UInt16(20))         // version needed
            directory.append(little: UInt16(0))          // flags
            directory.append(little: methodStored)
            directory.append(little: UInt16(0))
            directory.append(little: UInt16(0))
            directory.append(little: crc32(file.data))
            directory.append(little: UInt32(file.data.count))
            directory.append(little: UInt32(file.data.count))
            directory.append(little: UInt16(name.count))
            directory.append(little: UInt16(0))          // extra
            directory.append(little: UInt16(0))          // comment
            directory.append(little: UInt16(0))          // disk number
            directory.append(little: UInt16(0))          // internal attributes
            directory.append(little: UInt32(0))          // external attributes
            directory.append(little: UInt32(offsets[index]))
            directory.append(name)
        }

        let directoryOffset = output.count
        output.append(directory)
        output.append(little: endOfDirectorySignature)
        output.append(little: UInt16(0))                 // this disk
        output.append(little: UInt16(0))                 // directory start disk
        output.append(little: UInt16(files.count))
        output.append(little: UInt16(files.count))
        output.append(little: UInt32(directory.count))
        output.append(little: UInt32(directoryOffset))
        output.append(little: UInt16(0))                 // comment length
        return output
    }

    /// CRC-32 as zip defines it. Table built once — the naive bitwise form
    /// runs eight times per byte, which is noticeable on a megabyte `.shp`.
    static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(little value: UInt32) {
        var raw = value.littleEndian
        append(Data(bytes: &raw, count: 4))
    }

    mutating func append(little value: UInt16) {
        var raw = value.littleEndian
        append(Data(bytes: &raw, count: 2))
    }
}
