//
//  WholeFileCompressionTests.swift
//  AXTermTests
//
//  TDD tests for whole-file compression in file transfers.
//  The key insight: compression MUST be applied to the entire file BEFORE chunking,
//  not to individual chunks. Small chunks (128 bytes) don't compress well and often expand.
//
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 6.x.4
//

import XCTest
@testable import AXTerm

final class WholeFileCompressionTests: XCTestCase {

    // MARK: - Core Compression Tests

    func testSmallDataDoesNotBenefitFromCompression() {
        // This test documents the fundamental problem: small chunks don't compress well
        let smallData = Data(repeating: 0x42, count: 128)

        let compressed = AXDPCompression.compress(smallData, algorithm: .lz4)

        // Compression should return nil (no benefit) for small repetitive data
        // or return data that's larger than the original
        if let compressedData = compressed {
            // If it did compress, it should not be smaller
            XCTAssertGreaterThanOrEqual(compressedData.count, smallData.count,
                "Small uniform data should not benefit from compression")
        }
        // nil is also acceptable (means no benefit)
    }

    func testLargeRepetitiveDataCompressesWell() {
        // Large data with patterns compresses significantly
        let largeData = Data(repeating: 0x42, count: 4096)

        let compressed = AXDPCompression.compress(largeData, algorithm: .lz4)

        XCTAssertNotNil(compressed, "Large repetitive data should compress")
        XCTAssertLessThan(compressed!.count, largeData.count / 2,
            "Large repetitive data should compress to less than half size")
    }

    func testTextDataCompressesWell() {
        // Realistic text content (like a log file or source code) compresses well
        let textContent = """
        This is a sample text file that contains some repetitive content.
        The quick brown fox jumps over the lazy dog.
        The quick brown fox jumps over the lazy dog.
        The quick brown fox jumps over the lazy dog.
        Lorem ipsum dolor sit amet, consectetur adipiscing elit.
        Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
        Lorem ipsum dolor sit amet, consectetur adipiscing elit.
        Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
        """
        let textData = Data(textContent.utf8)

        let compressed = AXDPCompression.compress(textData, algorithm: .lz4)

        XCTAssertNotNil(compressed, "Text data should compress")
        if let compressedData = compressed {
            XCTAssertLessThan(compressedData.count, textData.count,
                "Text data should compress smaller than original")

            // Verify round-trip
            let decompressed = AXDPCompression.decompress(
                compressedData,
                algorithm: .lz4,
                originalLength: UInt32(textData.count),
                maxLength: AXDPCompression.absoluteMaxDecompressedLen
            )
            XCTAssertEqual(decompressed, textData, "Decompressed data should match original")
        }
    }

    // MARK: - Whole-File Compression Strategy Tests

    func testWholeFileCompressionIsBetterThanPerChunk() {
        // This test proves why whole-file compression is the correct approach
        let fileContent = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 100)
        let fileData = Data(fileContent.utf8)
        let chunkSize = 128

        // Strategy 1: Compress whole file (correct approach)
        let wholeFileCompressed = AXDPCompression.compress(fileData, algorithm: .lz4)

        // Strategy 2: Compress each chunk individually (current broken approach)
        var perChunkTotalSize = 0
        var chunksCompressed = 0
        var chunksUncompressed = 0

        let totalChunks = (fileData.count + chunkSize - 1) / chunkSize
        for i in 0..<totalChunks {
            let start = i * chunkSize
            let end = min(start + chunkSize, fileData.count)
            let chunkData = fileData.subdata(in: start..<end)

            if let compressed = AXDPCompression.compress(chunkData, algorithm: .lz4) {
                perChunkTotalSize += compressed.count
                chunksCompressed += 1
            } else {
                perChunkTotalSize += chunkData.count
                chunksUncompressed += 1
            }
        }

        // Whole-file compression should be significantly better
        XCTAssertNotNil(wholeFileCompressed, "Whole file should compress")
        if let wholeSize = wholeFileCompressed?.count {
            XCTAssertLessThan(wholeSize, perChunkTotalSize,
                "Whole-file compression (\(wholeSize) bytes) should be smaller than per-chunk (\(perChunkTotalSize) bytes)")

            // Log the improvement for documentation
            let improvement = Double(perChunkTotalSize - wholeSize) / Double(perChunkTotalSize) * 100
            print("Compression improvement: whole-file saves \(String(format: "%.1f", improvement))% vs per-chunk")
            print("Chunks compressed: \(chunksCompressed), uncompressed: \(chunksUncompressed)")
        }
    }

    // MARK: - File Transfer Compression Integration Tests

    func testTransferWithWholeFileCompression() {
        // Create compressible file data
        let fileContent = String(repeating: "Test data line with some content. ", count: 200)
        let originalData = Data(fileContent.utf8)

        // Compress the whole file
        guard let compressedData = AXDPCompression.compress(originalData, algorithm: .lz4) else {
            XCTFail("Test data should be compressible")
            return
        }

        // Create transfer using compressed data
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: originalData.count,  // Original size for progress tracking
            destination: "N0CALL",
            chunkSize: 128
        )

        // Set compression metrics
        transfer.setCompressionMetrics(
            algorithm: .lz4,
            originalSize: originalData.count,
            compressedSize: compressedData.count
        )

        // Verify metrics
        XCTAssertNotNil(transfer.compressionMetrics)
        XCTAssertEqual(transfer.compressionMetrics?.algorithm, .lz4)
        XCTAssertEqual(transfer.compressionMetrics?.originalSize, originalData.count)
        XCTAssertEqual(transfer.compressionMetrics?.compressedSize, compressedData.count)
        XCTAssertTrue(transfer.compressionMetrics?.wasEffective ?? false)
        XCTAssertGreaterThan(transfer.compressionMetrics?.savingsPercent ?? 0, 0)
    }

    func testTransferCompressionMetricsDisplay() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 10000,
            destination: "N0CALL"
        )

        // No compression
        transfer.setCompressionMetrics(algorithm: nil, originalSize: 10000, compressedSize: 10000)
        XCTAssertEqual(transfer.compressionMetrics?.summary, "Uncompressed")
        XCTAssertFalse(transfer.compressionUsed)

        // With effective compression
        transfer.setCompressionMetrics(algorithm: .lz4, originalSize: 10000, compressedSize: 5000)
        XCTAssertTrue(transfer.compressionMetrics?.summary.contains("LZ4") ?? false)
        XCTAssertTrue(transfer.compressionMetrics?.summary.contains("50%") ?? false)
        XCTAssertTrue(transfer.compressionUsed)
        XCTAssertEqual(transfer.compressionMetrics?.savingsPercent ?? 0, 50.0, accuracy: 0.1)

        // Compression didn't help (same size)
        transfer.setCompressionMetrics(algorithm: .lz4, originalSize: 100, compressedSize: 100)
        XCTAssertFalse(transfer.compressionMetrics?.wasEffective ?? true)
    }

    // MARK: - Compressibility Analysis Tests

    func testCompressibilityAnalysisForTextFile() {
        let textData = Data(String(repeating: "Hello World! ", count: 100).utf8)
        let analysis = CompressionAnalyzer.analyze(textData, fileName: "test.txt")

        XCTAssertTrue(analysis.isCompressible)
        XCTAssertEqual(analysis.fileCategory, .text)
    }

    func testCompressibilityAnalysisForJPEG() {
        // JPEG magic bytes
        var jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        jpegData.append(Data(repeating: 0x00, count: 1000))

        let analysis = CompressionAnalyzer.analyze(jpegData, fileName: "photo.jpg")

        XCTAssertFalse(analysis.isCompressible, "JPEG files are already compressed")
        XCTAssertEqual(analysis.fileCategory, .image)
    }

    func testCompressibilityAnalysisForZIP() {
        // ZIP magic bytes
        let zipData = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0x00, count: 1000)

        let analysis = CompressionAnalyzer.analyze(zipData, fileName: "archive.zip")

        XCTAssertFalse(analysis.isCompressible, "ZIP files are already compressed")
        XCTAssertEqual(analysis.fileCategory, .archive)
    }

    func testCompressibilityAnalysisForSmallFile() {
        let smallData = Data(repeating: 0x42, count: 32)

        let analysis = CompressionAnalyzer.analyze(smallData)

        XCTAssertFalse(analysis.isCompressible, "Very small files have too much overhead")
    }

    // MARK: - AXDP Message Compression TLV Tests

    func testFileMetaIncludesCompressionInfo() {
        // When whole-file compression is used, FILE_META should indicate the algorithm
        let fileMeta = AXDPFileMeta(
            filename: "test.txt",
            fileSize: 5000,  // Original uncompressed size
            sha256: Data(repeating: 0xAB, count: 32),
            chunkSize: 128
        )

        // Encode and decode
        let encoded = fileMeta.encode()
        let decoded = AXDPFileMeta.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.filename, "test.txt")
        XCTAssertEqual(decoded?.fileSize, 5000)
    }

    func testFileMetaMessageEncodesCompressionAlgorithm() {
        // CRITICAL TEST: Verify that FILE_META messages encode the compression algorithm
        // so receivers know to decompress the reassembled file
        let fileMeta = AXDPFileMeta(
            filename: "compressed.txt",
            fileSize: 10000,
            sha256: Data(repeating: 0xAB, count: 32),
            chunkSize: 128
        )

        // Create FILE_META message WITH compression algorithm (whole-file compression)
        let message = AXDP.Message(
            type: .fileMeta,
            sessionId: 12345,
            messageId: 0,
            totalChunks: 78,
            compression: .lz4,  // This MUST be encoded in the message
            fileMeta: fileMeta
        )

        // Encode and decode
        let encoded = message.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        // Verify the compression algorithm is preserved
        XCTAssertNotNil(decoded, "FILE_META message should decode successfully")
        XCTAssertEqual(decoded?.type, .fileMeta)
        XCTAssertEqual(decoded?.compression, .lz4, "Compression algorithm MUST be preserved in FILE_META")
        XCTAssertEqual(decoded?.totalChunks, 78)
        XCTAssertNotNil(decoded?.fileMeta)
        XCTAssertEqual(decoded?.fileMeta?.filename, "compressed.txt")
    }

    func testFileMetaMessageWithNoCompression() {
        // Verify FILE_META works correctly with no compression
        let fileMeta = AXDPFileMeta(
            filename: "uncompressed.bin",
            fileSize: 5000,
            sha256: Data(repeating: 0xCD, count: 32),
            chunkSize: 128
        )

        let message = AXDP.Message(
            type: .fileMeta,
            sessionId: 99999,
            messageId: 0,
            totalChunks: 40,
            compression: AXDPCompression.Algorithm.none,  // No compression
            fileMeta: fileMeta
        )

        let encoded = message.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.compression, AXDPCompression.Algorithm.none)
        XCTAssertEqual(decoded?.fileMeta?.filename, "uncompressed.bin")
    }

    func testChunkMessagesWithPreCompressedData() {
        // When file is pre-compressed, chunks should be sent WITHOUT per-chunk compression
        let preCompressedChunk = Data(repeating: 0x42, count: 128)

        // Create chunk message with compression = .none (data is already compressed)
        let chunkMessage = AXDP.Message(
            type: .fileChunk,
            sessionId: 12345,
            messageId: 1,
            chunkIndex: 0,
            totalChunks: 10,
            payload: preCompressedChunk,
            compression: AXDPCompression.Algorithm.none  // Important: no per-chunk compression
        )

        let encoded = chunkMessage.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.payload, preCompressedChunk)
        // Note: Use explicit type to avoid ambiguity with Optional.none
        XCTAssertEqual(decoded?.compression, AXDPCompression.Algorithm.none)
    }

    // MARK: - Round-Trip Compression Tests

    func testCompressionDecompressionRoundTrip() {
        let originalData = Data(String(repeating: "The quick brown fox ", count: 100).utf8)

        // Compress
        guard let compressed = AXDPCompression.compress(originalData, algorithm: .lz4) else {
            XCTFail("Data should compress")
            return
        }

        // Decompress
        let decompressed = AXDPCompression.decompress(
            compressed,
            algorithm: .lz4,
            originalLength: UInt32(originalData.count),
            maxLength: AXDPCompression.absoluteMaxDecompressedLen
        )

        XCTAssertNotNil(decompressed)
        XCTAssertEqual(decompressed, originalData)
    }

    func testDeflateCompressionRoundTrip() {
        let originalData = Data(String(repeating: "Deflate test content ", count: 100).utf8)

        guard let compressed = AXDPCompression.compress(originalData, algorithm: .deflate) else {
            XCTFail("Data should compress with deflate")
            return
        }

        let decompressed = AXDPCompression.decompress(
            compressed,
            algorithm: .deflate,
            originalLength: UInt32(originalData.count),
            maxLength: AXDPCompression.absoluteMaxDecompressedLen
        )

        XCTAssertNotNil(decompressed)
        XCTAssertEqual(decompressed, originalData)
    }

    // MARK: - Edge Cases

    func testCompressionWithEmptyData() {
        let emptyData = Data()

        let compressed = AXDPCompression.compress(emptyData, algorithm: .lz4)

        // Empty data should return empty data (no compression needed)
        XCTAssertEqual(compressed, emptyData)
    }

    func testCompressionWithHighEntropyData() {
        // Random data doesn't compress (high entropy)
        var randomData = Data(count: 1024)
        for i in 0..<randomData.count {
            randomData[i] = UInt8.random(in: 0...255)
        }

        let compressed = AXDPCompression.compress(randomData, algorithm: .lz4)

        // Should return nil (compression didn't help) or data that's not smaller
        if let compressedData = compressed {
            XCTAssertGreaterThanOrEqual(compressedData.count, randomData.count)
        }
        // nil is acceptable - means compression was skipped
    }

    func testDecompressionRejectsOversizedClaim() {
        // Ensure we can't be tricked by malicious originalLength claims
        let smallData = Data([0x01, 0x02, 0x03, 0x04])

        let result = AXDPCompression.decompress(
            smallData,
            algorithm: .lz4,
            originalLength: AXDPCompression.absoluteMaxDecompressedLen + 1,  // Exceeds limit
            maxLength: AXDPCompression.absoluteMaxDecompressedLen
        )

        XCTAssertNil(result, "Should reject originalLength exceeding absoluteMaxDecompressedLen")
    }

    // MARK: - File Transfer Limit Tests

    func testFileTransferLimitIsLargerThanPerMessageLimit() {
        // File transfers need a much larger limit than per-message compression
        XCTAssertGreaterThan(
            AXDPCompression.absoluteMaxFileTransferLen,
            AXDPCompression.absoluteMaxDecompressedLen,
            "File transfer limit should be larger than per-message limit"
        )

        // File transfer limit should be at least 1 MB (reasonable for most packet radio files)
        XCTAssertGreaterThanOrEqual(
            AXDPCompression.absoluteMaxFileTransferLen,
            1_000_000,
            "File transfer limit should be at least 1 MB"
        )
    }

    func testLargerFileCompressionRoundTrip() {
        // Test compressing and decompressing a file larger than the per-message limit (8KB)
        // but within the file transfer limit
        let largeFileContent = String(repeating: "This is test content for a larger file transfer. ", count: 500)
        let originalData = Data(largeFileContent.utf8)

        // Verify the test data is larger than per-message limit
        XCTAssertGreaterThan(originalData.count, Int(AXDPCompression.absoluteMaxDecompressedLen),
            "Test data should exceed per-message limit to validate fix")

        // Compress
        guard let compressed = AXDPCompression.compress(originalData, algorithm: .lz4) else {
            XCTFail("Large file should compress")
            return
        }

        XCTAssertLessThan(compressed.count, originalData.count,
            "Compressed data should be smaller")

        // Decompress using the FILE TRANSFER limit (not per-message limit)
        let decompressed = AXDPCompression.decompress(
            compressed,
            algorithm: .lz4,
            originalLength: UInt32(originalData.count),
            maxLength: AXDPCompression.absoluteMaxFileTransferLen  // Use file transfer limit
        )

        XCTAssertNotNil(decompressed, "Should decompress successfully with file transfer limit")
        XCTAssertEqual(decompressed, originalData, "Decompressed data should match original")
    }

    func testLargerFileFailsWithPerMessageLimit() {
        // Verify that larger files fail with per-message limit (validates the original bug)
        let largeFileContent = String(repeating: "This is test content for a larger file transfer. ", count: 500)
        let originalData = Data(largeFileContent.utf8)

        // Verify the test data exceeds per-message limit
        XCTAssertGreaterThan(originalData.count, Int(AXDPCompression.absoluteMaxDecompressedLen))

        guard let compressed = AXDPCompression.compress(originalData, algorithm: .lz4) else {
            XCTFail("Large file should compress")
            return
        }

        // Try to decompress with PER-MESSAGE limit - this should fail
        let result = AXDPCompression.decompress(
            compressed,
            algorithm: .lz4,
            originalLength: UInt32(originalData.count),
            maxLength: AXDPCompression.absoluteMaxDecompressedLen  // Per-message limit (too small)
        )

        XCTAssertNil(result, "Should fail decompression when file exceeds per-message limit")
    }
}
