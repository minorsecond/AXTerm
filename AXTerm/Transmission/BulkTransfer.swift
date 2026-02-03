//
//  BulkTransfer.swift
//  AXTerm
//
//  Bulk file transfer model with progress, pause/resume, and failure handling.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10.10
//

import Foundation

// MARK: - Transfer Status

/// Status of a bulk file transfer.
enum BulkTransferStatus: Equatable, Sendable {
    case pending
    case awaitingAcceptance  // Waiting for receiver to accept (ACK) or decline (NACK)
    case sending
    case paused
    case completed
    case cancelled
    case failed(reason: String)
}

// MARK: - Transfer Direction

/// Direction of file transfer
enum TransferDirection: String, Sendable {
    case outbound = "Sending"
    case inbound = "Receiving"
}

// MARK: - Compression Override

/// Per-transfer compression settings that can override global defaults
struct TransferCompressionSettings: Sendable, Equatable {
    /// Override compression enabled state (nil = use global)
    var enabledOverride: Bool?

    /// Override compression algorithm (nil = use global)
    var algorithmOverride: AXDPCompression.Algorithm?

    /// Whether to use global settings
    var useGlobalSettings: Bool {
        enabledOverride == nil && algorithmOverride == nil
    }

    /// Default: use global settings
    static let useGlobal = TransferCompressionSettings()

    /// Explicit: compression disabled for this transfer
    static let disabled = TransferCompressionSettings(enabledOverride: false)

    /// Explicit: use specific algorithm
    static func withAlgorithm(_ algorithm: AXDPCompression.Algorithm) -> TransferCompressionSettings {
        TransferCompressionSettings(enabledOverride: true, algorithmOverride: algorithm)
    }
}

// MARK: - Compression Metrics

/// Compression statistics for a transfer
struct TransferCompressionMetrics: Sendable, Equatable {
    /// Algorithm used (nil if no compression)
    let algorithm: AXDPCompression.Algorithm?

    /// Original uncompressed size in bytes
    let originalSize: Int

    /// Compressed size in bytes (same as original if not compressed)
    let compressedSize: Int

    /// Compression ratio (compressed/original, 1.0 = no compression)
    var ratio: Double {
        guard originalSize > 0 else { return 1.0 }
        return Double(compressedSize) / Double(originalSize)
    }

    /// Space saved percentage (0-100)
    var savingsPercent: Double {
        (1.0 - ratio) * 100.0
    }

    /// Bytes saved
    var bytesSaved: Int {
        max(0, originalSize - compressedSize)
    }

    /// Whether compression was beneficial
    var wasEffective: Bool {
        compressedSize < originalSize
    }

    /// Human-readable summary
    var summary: String {
        guard let algo = algorithm, wasEffective else {
            return "Uncompressed"
        }
        return "\(algo.displayName): \(String(format: "%.0f%%", savingsPercent)) smaller"
    }

    /// No compression metrics
    static func uncompressed(size: Int) -> TransferCompressionMetrics {
        TransferCompressionMetrics(algorithm: nil, originalSize: size, compressedSize: size)
    }
}

// MARK: - Compressibility Analysis

/// Result of analyzing data compressibility
struct CompressibilityAnalysis: Sendable {
    /// Estimated compression ratio if compressed
    let estimatedRatio: Double

    /// Whether compression is recommended
    let isCompressible: Bool

    /// Reason for recommendation
    let reason: String

    /// File type category
    let fileCategory: FileCategory

    enum FileCategory: String, Sendable {
        case text = "Text"
        case binary = "Binary"
        case alreadyCompressed = "Already Compressed"
        case image = "Image"
        case audio = "Audio"
        case archive = "Archive"
        case unknown = "Unknown"
    }

    /// Compression is recommended
    static func recommended(ratio: Double, reason: String, category: FileCategory) -> CompressibilityAnalysis {
        CompressibilityAnalysis(estimatedRatio: ratio, isCompressible: true, reason: reason, fileCategory: category)
    }

    /// Compression is not recommended
    static func notRecommended(reason: String, category: FileCategory) -> CompressibilityAnalysis {
        CompressibilityAnalysis(estimatedRatio: 1.0, isCompressible: false, reason: reason, fileCategory: category)
    }
}

/// Analyzes data to determine if compression would be beneficial
enum CompressionAnalyzer {

    /// File extensions that are already compressed
    private static let compressedExtensions: Set<String> = [
        "zip", "gz", "bz2", "xz", "7z", "rar", "tar.gz", "tgz",
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif",
        "mp3", "aac", "m4a", "ogg", "opus", "flac",
        "mp4", "mov", "avi", "mkv", "webm",
        "pdf", "docx", "xlsx", "pptx"
    ]

    /// Analyze data compressibility
    static func analyze(_ data: Data, fileName: String? = nil) -> CompressibilityAnalysis {
        // Check file extension first
        if let name = fileName {
            let ext = (name as NSString).pathExtension.lowercased()
            if compressedExtensions.contains(ext) {
                return categorizedNotRecommended(ext: ext)
            }
        }

        // Small files: compression overhead may not be worth it
        if data.count < 64 {
            return .notRecommended(
                reason: "File too small (\(data.count) bytes) - compression overhead exceeds benefit",
                category: .unknown
            )
        }

        // Sample entropy to estimate compressibility
        let entropy = calculateEntropy(data)
        let category = guessFileCategory(data, fileName: fileName)

        // High entropy = low compressibility
        if entropy > 7.5 {
            return .notRecommended(
                reason: "High entropy (\(String(format: "%.1f", entropy)) bits/byte) - likely already compressed or encrypted",
                category: category
            )
        }

        // Estimate ratio based on entropy
        // Entropy of 0 = perfect compression, entropy of 8 = no compression
        let estimatedRatio = entropy / 8.0

        if estimatedRatio > 0.9 {
            return .notRecommended(
                reason: "Estimated \(String(format: "%.0f%%", (1.0 - estimatedRatio) * 100)) savings - minimal benefit",
                category: category
            )
        }

        let savingsEstimate = (1.0 - estimatedRatio) * 100
        return .recommended(
            ratio: estimatedRatio,
            reason: "Estimated \(String(format: "%.0f%%", savingsEstimate)) savings",
            category: category
        )
    }

    /// Calculate Shannon entropy of data (bits per byte)
    private static func calculateEntropy(_ data: Data) -> Double {
        guard data.count > 0 else { return 0 }

        // Sample up to 4KB for performance
        let sampleSize = min(data.count, 4096)
        let sample = data.prefix(sampleSize)

        // Count byte frequencies
        var frequencies = [UInt8: Int]()
        for byte in sample {
            frequencies[byte, default: 0] += 1
        }

        // Calculate entropy
        var entropy: Double = 0
        let total = Double(sampleSize)

        for (_, count) in frequencies {
            let probability = Double(count) / total
            if probability > 0 {
                entropy -= probability * log2(probability)
            }
        }

        return entropy
    }

    /// Guess file category from data and extension
    private static func guessFileCategory(_ data: Data, fileName: String?) -> CompressibilityAnalysis.FileCategory {
        if let name = fileName {
            let ext = (name as NSString).pathExtension.lowercased()

            // Text files
            if ["txt", "md", "json", "xml", "html", "css", "js", "swift", "c", "h", "py", "log"].contains(ext) {
                return .text
            }

            // Images
            if ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff"].contains(ext) {
                return .image
            }

            // Audio
            if ["mp3", "wav", "aac", "flac", "ogg"].contains(ext) {
                return .audio
            }

            // Archives
            if ["zip", "gz", "tar", "7z", "rar"].contains(ext) {
                return .archive
            }
        }

        // Check magic bytes
        if data.count >= 4 {
            let magic = Array(data.prefix(4))

            // PNG
            if magic == [0x89, 0x50, 0x4E, 0x47] {
                return .alreadyCompressed
            }

            // JPEG
            if magic[0] == 0xFF && magic[1] == 0xD8 {
                return .alreadyCompressed
            }

            // GIF
            if magic[0...2] == [0x47, 0x49, 0x46] {
                return .alreadyCompressed
            }

            // ZIP/DOCX/etc
            if magic == [0x50, 0x4B, 0x03, 0x04] {
                return .archive
            }

            // GZIP
            if magic[0] == 0x1F && magic[1] == 0x8B {
                return .archive
            }
        }

        // Check if mostly printable ASCII (text-like)
        let sample = data.prefix(min(data.count, 512))
        let printableCount = sample.filter { (0x20...0x7E).contains($0) || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }.count
        if Double(printableCount) / Double(sample.count) > 0.85 {
            return .text
        }

        return .binary
    }

    /// Return appropriate not-recommended result based on file extension
    private static func categorizedNotRecommended(ext: String) -> CompressibilityAnalysis {
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif":
            return .notRecommended(reason: "Image files are already compressed", category: .image)
        case "mp3", "aac", "m4a", "ogg", "opus", "flac":
            return .notRecommended(reason: "Audio files are already compressed", category: .audio)
        case "mp4", "mov", "avi", "mkv", "webm":
            return .notRecommended(reason: "Video files are already compressed", category: .alreadyCompressed)
        case "zip", "gz", "bz2", "xz", "7z", "rar", "tar.gz", "tgz":
            return .notRecommended(reason: "Archive files are already compressed", category: .archive)
        case "pdf", "docx", "xlsx", "pptx":
            return .notRecommended(reason: "Document format includes compression", category: .alreadyCompressed)
        default:
            return .notRecommended(reason: "File type is typically already compressed", category: .alreadyCompressed)
        }
    }
}

// MARK: - Algorithm Display Extension

extension AXDPCompression.Algorithm {
    /// Human-readable display name
    var displayName: String {
        switch self {
        case .none: return "None"
        case .lz4: return "LZ4"
        case .zstd: return "ZSTD"
        case .deflate: return "Deflate"
        }
    }

    /// Short description
    var shortDescription: String {
        switch self {
        case .none: return "No compression"
        case .lz4: return "Fast"
        case .zstd: return "Balanced"
        case .deflate: return "Best ratio"
        }
    }
}

// MARK: - Bulk Transfer Model

/// Represents a file transfer in progress or completed.
struct BulkTransfer: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let fileSize: Int
    let destination: String
    let chunkSize: Int

    /// Direction of transfer
    let direction: TransferDirection

    /// Transfer protocol being used
    let transferProtocol: TransferProtocolType

    /// Current status
    var status: BulkTransferStatus = .pending

    /// Bytes successfully acknowledged (sent) or received
    var bytesSent: Int = 0

    /// Bytes actually transmitted over the air (may differ due to compression)
    var bytesTransmitted: Int = 0

    /// Timing
    var startedAt: Date?
    var completedAt: Date?

    /// Compression settings for this transfer (can override global)
    var compressionSettings: TransferCompressionSettings = .useGlobal

    /// Compressibility analysis result
    var compressibilityAnalysis: CompressibilityAnalysis?

    /// Compression metrics (populated after compression applied)
    var compressionMetrics: TransferCompressionMetrics?

    /// Path where received file was saved (inbound transfers only)
    var savedFilePath: String?

    /// Whether compression was actually used
    var compressionUsed: Bool {
        compressionMetrics?.algorithm != nil && compressionMetrics?.wasEffective == true
    }

    /// Effective compression ratio (1.0 if no compression)
    var effectiveCompressionRatio: Double {
        compressionMetrics?.ratio ?? 1.0
    }

    /// Chunk tracking
    private var sentChunks: Set<Int> = []
    private var completedChunks_: Set<Int> = []
    private var retryChunks: Set<Int> = []

    init(
        id: UUID,
        fileName: String,
        fileSize: Int,
        destination: String,
        chunkSize: Int = 128,
        direction: TransferDirection = .outbound,
        transferProtocol: TransferProtocolType = .axdp,
        compressionSettings: TransferCompressionSettings = .useGlobal
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.destination = destination
        self.chunkSize = max(16, chunkSize)
        self.direction = direction
        self.transferProtocol = transferProtocol
        self.compressionSettings = compressionSettings
    }

    /// Analyze compressibility of file data
    mutating func analyzeCompressibility(_ data: Data) {
        compressibilityAnalysis = CompressionAnalyzer.analyze(data, fileName: fileName)
    }

    /// Update compression metrics after compression
    mutating func setCompressionMetrics(algorithm: AXDPCompression.Algorithm?, originalSize: Int, compressedSize: Int) {
        compressionMetrics = TransferCompressionMetrics(
            algorithm: algorithm,
            originalSize: originalSize,
            compressedSize: compressedSize
        )
    }

    // MARK: - Progress

    /// Transfer progress (0.0 to 1.0)
    var progress: Double {
        guard fileSize > 0 else { return 1.0 }
        return min(1.0, Double(bytesSent) / Double(fileSize))
    }

    // MARK: - State Checks

    /// Whether transfer can be paused
    var canPause: Bool {
        status == .sending
    }

    /// Whether transfer can be resumed
    var canResume: Bool {
        status == .paused
    }

    /// Whether transfer can be cancelled
    var canCancel: Bool {
        switch status {
        case .pending, .awaitingAcceptance, .sending, .paused:
            return true
        case .completed, .cancelled, .failed:
            return false
        }
    }

    // MARK: - Failure

    /// Human-readable failure explanation
    var failureExplanation: String {
        if case .failed(let reason) = status {
            return reason
        }
        return ""
    }

    // MARK: - Timing

    /// Mark transfer as started
    mutating func markStarted() {
        startedAt = Date()
    }

    /// Mark transfer as completed
    mutating func markCompleted() {
        completedAt = Date()
        status = .completed
    }

    /// Throughput in bytes per second (data throughput, not air throughput)
    var throughputBytesPerSecond: Double {
        guard let start = startedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        return Double(bytesSent) / elapsed
    }

    /// Air throughput in bytes per second (actual transmitted bytes)
    var airThroughputBytesPerSecond: Double {
        guard let start = startedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        return Double(bytesTransmitted) / elapsed
    }

    /// Estimated seconds remaining
    var estimatedSecondsRemaining: Double? {
        let throughput = throughputBytesPerSecond
        guard throughput > 0 else { return nil }
        let remaining = fileSize - bytesSent
        return Double(remaining) / throughput
    }

    /// Format throughput for display (bits per second)
    var throughputDisplay: String {
        formatBitRate(throughputBytesPerSecond * 8)
    }

    /// Format air throughput for display (bits per second)
    var airThroughputDisplay: String {
        formatBitRate(airThroughputBytesPerSecond * 8)
    }

    /// Format bit rate for human readable display
    private func formatBitRate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond < 1000 {
            return String(format: "%.0f bps", bitsPerSecond)
        } else if bitsPerSecond < 1_000_000 {
            return String(format: "%.1f kbps", bitsPerSecond / 1000)
        } else {
            return String(format: "%.2f Mbps", bitsPerSecond / 1_000_000)
        }
    }

    /// Bandwidth efficiency (actual data / transmitted)
    var bandwidthEfficiency: Double {
        guard bytesTransmitted > 0 else { return 1.0 }
        return Double(bytesSent) / Double(bytesTransmitted)
    }

    // MARK: - Chunk Management

    /// Total number of chunks
    var totalChunks: Int {
        guard fileSize > 0 else { return 0 }
        return (fileSize + chunkSize - 1) / chunkSize
    }

    /// Number of completed chunks
    var completedChunks: Int {
        completedChunks_.count
    }

    /// Mark a chunk as sent (awaiting ack)
    mutating func markChunkSent(_ chunk: Int) {
        sentChunks.insert(chunk)
        retryChunks.remove(chunk)
    }

    /// Mark a chunk as completed (acked)
    mutating func markChunkCompleted(_ chunk: Int) {
        completedChunks_.insert(chunk)
        sentChunks.remove(chunk)
        retryChunks.remove(chunk)

        // Update bytesSent
        bytesSent = completedChunks_.reduce(0) { total, c in
            let start = c * chunkSize
            let end = min(start + chunkSize, fileSize)
            return total + (end - start)
        }
    }

    /// Mark a chunk as needing retry
    mutating func markChunkNeedsRetry(_ chunk: Int) {
        sentChunks.remove(chunk)
        if !completedChunks_.contains(chunk) {
            retryChunks.insert(chunk)
        }
    }

    /// Next chunk index to send, or nil if all sent
    var nextChunkToSend: Int? {
        // First, handle retries
        if let retry = retryChunks.min() {
            return retry
        }

        // Then, find next unsent chunk
        for chunk in 0..<totalChunks {
            if !sentChunks.contains(chunk) && !completedChunks_.contains(chunk) {
                return chunk
            }
        }

        return nil
    }

    // MARK: - Data Access

    /// Get chunk data from file data
    func chunkData(from fileData: Data, chunk: Int) -> Data? {
        let start = chunk * chunkSize
        guard start < fileData.count else { return nil }

        let end = min(start + chunkSize, fileData.count)
        return fileData.subdata(in: start..<end)
    }
}

// MARK: - Bulk Transfer Manager

/// Manages multiple file transfers.
struct BulkTransferManager: Sendable {
    /// All transfers (active and completed)
    private(set) var transfers: [BulkTransfer] = []

    /// File data cache (keyed by transfer ID)
    private var fileDataCache: [UUID: Data] = [:]

    /// Enqueue a new file transfer.
    @discardableResult
    mutating func enqueue(
        fileName: String,
        fileData: Data,
        destination: String,
        chunkSize: Int = 128
    ) -> UUID? {
        let id = UUID()
        let transfer = BulkTransfer(
            id: id,
            fileName: fileName,
            fileSize: fileData.count,
            destination: destination,
            chunkSize: chunkSize
        )

        transfers.append(transfer)
        fileDataCache[id] = fileData

        return id
    }

    /// Get transfer by ID
    func transfer(for id: UUID) -> BulkTransfer? {
        transfers.first { $0.id == id }
    }

    /// Start a transfer
    mutating func start(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        guard transfers[index].status == .pending else { return }

        transfers[index].status = .sending
        transfers[index].markStarted()
    }

    /// Pause a transfer
    mutating func pause(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        guard transfers[index].canPause else { return }

        transfers[index].status = .paused
    }

    /// Resume a paused transfer
    mutating func resume(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        guard transfers[index].canResume else { return }

        transfers[index].status = .sending
    }

    /// Cancel a transfer
    mutating func cancel(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        guard transfers[index].canCancel else { return }

        transfers[index].status = .cancelled
        fileDataCache.removeValue(forKey: id)
    }

    /// Mark transfer as failed
    mutating func fail(_ id: UUID, reason: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].status = .failed(reason: reason)
    }

    /// Mark transfer as completed
    mutating func complete(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].markCompleted()
        fileDataCache.removeValue(forKey: id)
    }

    /// Get file data for transfer
    func fileData(for id: UUID) -> Data? {
        fileDataCache[id]
    }

    /// Active transfers (pending, awaiting, or sending)
    var activeTransfers: [BulkTransfer] {
        transfers.filter { transfer in
            switch transfer.status {
            case .pending, .awaitingAcceptance, .sending, .paused:
                return true
            default:
                return false
            }
        }
    }

    /// Completed transfers (success, cancelled, or failed)
    var completedTransfers: [BulkTransfer] {
        transfers.filter { transfer in
            switch transfer.status {
            case .completed, .cancelled, .failed:
                return true
            default:
                return false
            }
        }
    }

    /// Clear completed transfers
    mutating func clearCompleted() {
        transfers.removeAll { transfer in
            switch transfer.status {
            case .completed, .cancelled, .failed:
                fileDataCache.removeValue(forKey: transfer.id)
                return true
            default:
                return false
            }
        }
    }
}
