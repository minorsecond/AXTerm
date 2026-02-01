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
    case sending
    case paused
    case completed
    case cancelled
    case failed(reason: String)
}

// MARK: - Bulk Transfer Model

/// Represents a file transfer in progress or completed.
struct BulkTransfer: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let fileSize: Int
    let destination: String
    let chunkSize: Int

    /// Current status
    var status: BulkTransferStatus = .pending

    /// Bytes successfully acknowledged
    var bytesSent: Int = 0

    /// Timing
    var startedAt: Date?
    var completedAt: Date?

    /// Chunk tracking
    private var sentChunks: Set<Int> = []
    private var completedChunks_: Set<Int> = []
    private var retryChunks: Set<Int> = []

    init(
        id: UUID,
        fileName: String,
        fileSize: Int,
        destination: String,
        chunkSize: Int = 128
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.destination = destination
        self.chunkSize = max(16, chunkSize)
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
        case .pending, .sending, .paused:
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

    /// Throughput in bytes per second
    var throughputBytesPerSecond: Double {
        guard let start = startedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        return Double(bytesSent) / elapsed
    }

    /// Estimated seconds remaining
    var estimatedSecondsRemaining: Double? {
        let throughput = throughputBytesPerSecond
        guard throughput > 0 else { return nil }
        let remaining = fileSize - bytesSent
        return Double(remaining) / throughput
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

    /// Active transfers (pending or sending)
    var activeTransfers: [BulkTransfer] {
        transfers.filter { transfer in
            switch transfer.status {
            case .pending, .sending, .paused:
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
