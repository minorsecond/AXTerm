//
//  BulkTransferView.swift
//  AXTerm
//
//  Bulk file transfer UI: progress, pause/resume, failure explanations.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10.10 & 12
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Transfer Row View

/// Individual transfer row with progress and controls
struct BulkTransferRow: View {
    let transfer: BulkTransfer
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack {
                // Direction indicator
                Image(systemName: transfer.direction == .outbound ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(transfer.direction == .outbound ? .blue : .green)
                    .font(.caption)

                // File icon
                Image(systemName: fileIcon)
                    .foregroundStyle(.secondary)

                // File name
                Text(transfer.fileName)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)

                // Protocol badge
                transferProtocolBadge(transfer.transferProtocol)

                // Compression badge - show when compression was used
                if let metrics = transfer.compressionMetrics, metrics.wasEffective {
                    compressionBadge(metrics)
                } else if let metrics = transfer.compressionMetrics, metrics.algorithm != nil && !metrics.wasEffective {
                    // Compression was attempted but not effective
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.caption2)
                        Text("No savings")
                    }
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
                    .help("Compression was attempted but provided no benefit")
                }

                Spacer()

                // Status badge
                statusBadge

                // Info button
                Button {
                    showDetails.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Show transfer details")

                // Control buttons
                if transfer.canPause {
                    Button(action: onPause) {
                        Image(systemName: "pause.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Pause transfer")
                }

                if transfer.canResume {
                    Button(action: onResume) {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Resume transfer")
                }

                if transfer.canCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Cancel transfer")
                }
            }

            // Progress bar (if active)
            if isActive {
                ProgressView(value: transfer.progress)
                    .progressViewStyle(.linear)
                    .animation(.easeInOut(duration: 0.3), value: transfer.progress)

                // Stats row
                HStack(spacing: 12) {
                    // Bytes progress
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Throughput (data rate)
                    if transfer.throughputBytesPerSecond > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "speedometer")
                                .font(.caption2)
                            Text(transfer.throughputDisplay)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Data throughput")
                    }

                    // Air throughput - shows actual bytes over the air
                    if transfer.airThroughputBytesPerSecond > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption2)
                            Text(transfer.airThroughputDisplay)
                        }
                        .font(.caption)
                        .foregroundStyle(transfer.compressionUsed ? .tertiary : .secondary)
                        .help(transfer.compressionUsed
                              ? "Air interface throughput (compressed data)"
                              : "Air interface throughput")
                    }

                    // ETA
                    if let eta = transfer.estimatedSecondsRemaining {
                        Text(etaText(eta))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Expanded details panel
            if showDetails {
                transferDetailsView
            }

            // Compressibility warning (for outbound pending transfers)
            if transfer.direction == .outbound,
               transfer.status == .pending,
               let analysis = transfer.compressibilityAnalysis,
               !analysis.isCompressible {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text(analysis.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Failure explanation (if failed)
            if case .failed(let reason) = transfer.status {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Compression Badge

    /// Protocol badge for transfer row
    @ViewBuilder
    private func transferProtocolBadge(_ proto: TransferProtocolType) -> some View {
        let color: Color = {
            switch proto {
            case .axdp: return .blue
            case .yapp: return .green
            case .sevenPlus: return .orange
            case .rawBinary: return .gray
            }
        }()

        Text(proto.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .help(proto.shortDescription)
    }

    @ViewBuilder
    private func compressionBadge(_ metrics: TransferCompressionMetrics) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.caption2)
            Text(metrics.algorithm?.displayName ?? "")
            Text(String(format: "-%.0f%%", metrics.savingsPercent))
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.green.opacity(0.2))
        .foregroundStyle(.green)
        .clipShape(Capsule())
        .help("Compression: \(metrics.summary)")
    }

    // MARK: - Transfer Details View

    @ViewBuilder
    private var transferDetailsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            // File info
            detailRow("Original Size", formatBytes(transfer.fileSize), help: "Uncompressed file size on disk.")
            if transfer.compressionUsed && transfer.transmissionSize != transfer.fileSize {
                detailRow("Transfer Size", formatBytes(transfer.transmissionSize), help: "Bytes sent over the air for this transfer. When compression is used, this reflects the compressed size.")
            }
            detailRow(transfer.direction == .inbound ? "From" : "To", transfer.destination, help: "Remote station for this transfer.")
            detailRow("Protocol", transfer.transferProtocol.displayName, help: "Transfer protocol used for this session.")
            detailRow("Chunk Size", "\(transfer.chunkSize) bytes", help: "Payload bytes per chunk before AXDP framing. Smaller chunks trade efficiency for reliability.")
            detailRow("Chunks", "\(transfer.completedChunks)/\(transfer.totalChunks)", help: "Progress in chunks received/sent out of total.")

            // Compression info - show during transfer or after completion
            if transfer.compressionSettings != .disabled || transfer.compressionMetrics != nil {
                Divider()
                Text("Compression")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                if let metrics = transfer.compressionMetrics {
                    // Completed transfer - show full metrics
                    detailRow("Algorithm", metrics.algorithm?.displayName ?? "None", help: "Compression algorithm used for the file payload.")
                    detailRow("Original Size", formatBytes(metrics.originalSize), help: "Size of the file before compression.")
                    detailRow("Compressed Size", formatBytes(metrics.compressedSize), help: "Total compressed payload bytes sent.")
                    if metrics.wasEffective {
                        detailRow("Savings", String(format: "%.1f%% smaller", metrics.savingsPercent), help: "Percent reduction vs original size.")
                    } else {
                        detailRow("Savings", "No benefit (stored uncompressed)", help: "Compression did not reduce size, so the transfer stored data uncompressed.")
                    }
                    detailRow("Bytes Saved", formatBytes(metrics.bytesSaved), help: "Original size minus compressed size.")
                } else if isActive {
                    // Active transfer - show settings
                    let settings = transfer.compressionSettings
                    if settings.useGlobalSettings {
                        detailRow("Mode", "Using global settings", help: "This transfer uses the global compression configuration.")
                    } else if let override = settings.enabledOverride {
                        detailRow("Enabled", override ? "Yes" : "No", help: "Per-transfer override to force compression on or off.")
                    }
                    if let algo = settings.algorithmOverride {
                        detailRow("Algorithm", algo.displayName, help: "Per-transfer compression algorithm override.")
                    }

                    // Show live compression ratio if available
                    if transfer.bytesTransmitted > 0 && transfer.bytesSent > 0 && transfer.bytesTransmitted != transfer.bytesSent {
                        let liveRatio = Double(transfer.bytesTransmitted) / Double(transfer.bytesSent)
                        if liveRatio < 1.0 {
                            detailRow("Live Ratio", String(format: "%.1f%% of original", liveRatio * 100), help: "Running ratio of bytes sent over the air vs original bytes so far.")
                        }
                    }
                } else {
                    detailRow("Status", "No compression used", help: "Compression was disabled for this transfer.")
                }
            }

            // Timing info
            if let dataStart = transfer.dataPhaseStart {
                Divider()
                Text("Timing")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                detailRow("Data Started", formatTime(dataStart), help: "Timestamp when the first data chunk was sent/received.")
                if let dataDuration = transfer.dataPhaseDurationSeconds {
                    let label = transfer.dataPhaseCompletedAt == nil ? "Data Elapsed" : "Data Duration"
                    detailRow(label, formatDuration(dataDuration), help: "Elapsed time from first data chunk to the latest (or last) data chunk.")
                }

                if let completed = transfer.completedAt {
                    detailRow("Completed", formatTime(completed), help: "Timestamp when the transfer finished.")
                    if let total = transfer.totalDurationSeconds {
                        detailRow("Total Duration", formatDuration(total), help: "Total elapsed time from transfer start to completion, including setup and processing.")
                    }
                    if let processing = transfer.processingDurationSeconds {
                        detailRow("Processing", formatDuration(processing), help: "Local post-transfer work such as reassembly, decompression, hashing, and file save. Small files can be near-zero.")
                    }
                }
            }

            // Throughput info
            if transfer.throughputBytesPerSecond > 0 {
                Divider()
                Text("Throughput")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                let useReceiverDuration = transfer.preferredRatesUseReceiverTiming
                let dataRateBps = transfer.preferredDataRateBytesPerSecond
                let dataRateDisplay = formatBitRate(dataRateBps * 8)
                let dataRateHelp = useReceiverDuration
                    ? "Payload bytes divided by receiver-reported data duration."
                    : "Payload bytes divided by data duration."
                detailRow("Data Rate", dataRateDisplay, help: dataRateHelp)
                if transfer.compressionUsed {
                    let airRateBps = transfer.preferredAirRateBytesPerSecond
                    let airRateDisplay = formatBitRate(airRateBps * 8)
                    let airRateHelp = useReceiverDuration
                        ? "Over-the-air bytes (including framing/compression) divided by receiver-reported data duration."
                        : "Over-the-air bytes (including framing/compression) divided by data duration."
                    detailRow("Air Rate", airRateDisplay, help: airRateHelp)

                    let efficiency = transfer.preferredBandwidthEfficiency
                    detailRow("Efficiency", String(format: "%.0f%%", efficiency * 100), help: "Data Rate divided by Air Rate.")
                }

                if transfer.direction == .outbound, let remote = transfer.remoteTransferMetrics {
                    detailRow("Rx Data Rate", formatBitRate(remote.dataBytesPerSecond * 8), help: "Receiver-reported payload bytes divided by receiver data duration.")
                    detailRow("Rx Data Duration", formatDuration(remote.dataDurationSeconds), help: "Receiver-reported time from first to last valid chunk.")
                    if remote.processingDurationSeconds > 0 {
                        detailRow("Rx Processing", formatDuration(remote.processingDurationSeconds), help: "Receiver-reported post-transfer processing time (reassembly/decompress/verify/save). Can be near-zero on small files.")
                    }
                }
            }
        }
        .padding(.top, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String, help: String? = nil) -> some View {
        let row = HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let help {
            row.help(help)
        } else {
            row
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else if seconds < 3600 {
            let mins = Int(seconds / 60)
            let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(mins)m \(secs)s"
        } else {
            let hours = Int(seconds / 3600)
            let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(mins)m"
        }
    }

    private func formatBitRate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond < 1000 {
            return String(format: "%.0f bps", bitsPerSecond)
        } else if bitsPerSecond < 1_000_000 {
            return String(format: "%.1f kbps", bitsPerSecond / 1000)
        } else {
            return String(format: "%.2f Mbps", bitsPerSecond / 1_000_000)
        }
    }

    // MARK: - Computed Properties

    private var isActive: Bool {
        switch transfer.status {
        case .pending, .awaitingAcceptance, .sending, .paused, .awaitingCompletion:
            return true
        default:
            return false
        }
    }

    private var fileIcon: String {
        // Simple icon based on extension
        let ext = (transfer.fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "log":
            return "doc.text"
        case "pdf":
            return "doc.richtext"
        case "zip", "gz", "tar":
            return "doc.zipper"
        case "png", "jpg", "jpeg", "gif":
            return "photo"
        default:
            return "doc"
        }
    }

    private var progressText: String {
        // Show progress against transmission size (compressed if applicable)
        let targetSize = transfer.transmissionSize > 0 ? transfer.transmissionSize : transfer.fileSize
        let sent = ByteCountFormatter.string(
            fromByteCount: Int64(transfer.bytesSent),
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(targetSize),
            countStyle: .file
        )

        // If compressed and different from original, show both
        if transfer.compressionUsed && targetSize != transfer.fileSize {
            let originalFormatted = ByteCountFormatter.string(
                fromByteCount: Int64(transfer.fileSize),
                countStyle: .file
            )
            return "\(sent) / \(total) (\(originalFormatted) uncompressed)"
        }
        return "\(sent) / \(total)"
    }

    private var throughputText: String {
        let bps = transfer.throughputBytesPerSecond
        let formatted = ByteCountFormatter.string(
            fromByteCount: Int64(bps),
            countStyle: .file
        )
        return "\(formatted)/s"
    }

    private func etaText(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s remaining"
        } else if seconds < 3600 {
            let mins = Int(seconds / 60)
            let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(mins)m \(secs)s remaining"
        } else {
            let hours = Int(seconds / 3600)
            let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(mins)m remaining"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch transfer.status {
        case .pending:
            if transfer.direction == .inbound {
                Label("Pending permission", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("Queued", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .awaitingAcceptance:
            Label("Pending permission", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .sending:
            // Show "Receiving" for inbound transfers, "Sending" for outbound
            if transfer.direction == .inbound {
                Label("Receiving", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("Sending", systemImage: "arrow.up.circle")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        case .paused:
            Label("Paused", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .awaitingCompletion:
            if transfer.direction == .inbound && transfer.compressionUsed {
                // Receiver with compression - show decompressing status
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                    Text("Decompressing")
                }
                .font(.caption)
                .foregroundStyle(.blue)
            } else if transfer.direction == .outbound {
                // Sender awaiting completion confirmation
                Label("Awaiting confirmation", systemImage: "checkmark.circle.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.blue)
            } else {
                Label("Finalizing", systemImage: "checkmark.circle.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        case .completed:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .cancelled:
            Label("Cancelled", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var backgroundColor: Color {
        switch transfer.status {
        case .failed:
            return Color.red.opacity(0.1)
        case .completed:
            return Color.green.opacity(0.1)
        default:
            return Color.secondary.opacity(0.1)
        }
    }
}

// MARK: - Transfer List View

/// List of all transfers with grouped sections
struct BulkTransferListView: View {
    let transfers: [BulkTransfer]
    var pendingIncomingTransfers: [IncomingTransferRequest] = []
    var suppressIncomingRequests: Bool = false
    let onPause: (UUID) -> Void
    let onResume: (UUID) -> Void
    let onCancel: (UUID) -> Void
    let onClearCompleted: () -> Void
    let onAddFile: () -> Void
    var onAcceptIncoming: ((UUID) -> Void)?
    var onDeclineIncoming: ((UUID) -> Void)?

    private var visibleIncomingRequests: [IncomingTransferRequest] {
        []
    }

    private var visibleTransfers: [BulkTransfer] {
        suppressIncomingRequests
            ? transfers.filter { $0.status != .awaitingAcceptance }
            : transfers
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("File Transfers")
                    .font(.headline)

                Spacer()

                if !completedTransfers.isEmpty {
                    Button("Clear Completed") {
                        onClearCompleted()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(action: onAddFile) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Add file to transfer")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Transfer list
            if visibleTransfers.isEmpty && visibleIncomingRequests.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.arrow.up")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("No file transfers")
                        .foregroundStyle(.secondary)

                    Text("Drag a file here or click + to add")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Active transfers
                        if !activeTransfers.isEmpty {
                            Section {
                                ForEach(activeTransfers) { transfer in
                                    BulkTransferRow(
                                        transfer: transfer,
                                        onPause: { onPause(transfer.id) },
                                        onResume: { onResume(transfer.id) },
                                        onCancel: { onCancel(transfer.id) }
                                    )
                                    // Force re-render when status or progress changes
                                    .id("\(transfer.id)-\(transfer.status)-\(transfer.completedChunks)")
                                }
                            } header: {
                                SectionHeader(title: "Active", count: activeTransfers.count)
                            }
                        }

                        // Completed transfers
                        if !completedTransfers.isEmpty {
                            Section {
                                ForEach(completedTransfers) { transfer in
                                    BulkTransferRow(
                                        transfer: transfer,
                                        onPause: { },
                                        onResume: { },
                                        onCancel: { }
                                    )
                                    // Force re-render when status changes
                                    .id("\(transfer.id)-\(transfer.status)")
                                }
                            } header: {
                                SectionHeader(title: "Completed", count: completedTransfers.count)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var activeTransfers: [BulkTransfer] {
        visibleTransfers.filter { transfer in
            switch transfer.status {
            case .pending, .sending, .paused, .awaitingCompletion:
                return true
            default:
                return false
            }
        }
    }

    private var completedTransfers: [BulkTransfer] {
        visibleTransfers.filter { transfer in
            switch transfer.status {
            case .completed, .cancelled, .failed:
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Text("\(count)")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.2))
                .clipShape(Capsule())

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Send File Sheet

/// Sheet for initiating a new file transfer with compression and protocol options
struct SendFileSheet: View {
    @Binding var isPresented: Bool
    let selectedFileURL: URL?
    let connectedSessions: [AX25Session]
    let onSend: (String, String, TransferProtocolType, TransferCompressionSettings) -> Void

    /// Optional closure to check AXDP capability status for a callsign
    var checkCapability: ((String) -> SessionCoordinator.CapabilityStatus)?

    /// Optional closure to get available protocols for a destination
    var availableProtocols: ((String) -> [TransferProtocolType])?

    @State private var selectedSessionIndex: Int = 0
    @State private var compressibilityAnalysis: CompressibilityAnalysis?
    @State private var compressionMode: CompressionMode = .useGlobal
    @State private var selectedAlgorithm: AXDPCompression.Algorithm = .lz4
    @State private var selectedProtocol: TransferProtocolType = .axdp
    @State private var showAdvanced = false

    enum CompressionMode: String, CaseIterable {
        case useGlobal = "Global"
        case enabled = "On"
        case disabled = "Off"
        case custom = "Custom"

        /// Full description for tooltips/help text
        var fullDescription: String {
            switch self {
            case .useGlobal: return "Use global compression settings"
            case .enabled: return "Enable compression for this transfer"
            case .disabled: return "Disable compression for this transfer"
            case .custom: return "Use custom compression algorithm"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Send File")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Content - use Form for proper macOS HIG layout
            Form {
                // File info section
                if let url = selectedFileURL {
                    Section {
                        fileInfoContent(url)
                    } header: {
                        Text("File")
                    }
                }

                // Destination section
                Section {
                    destinationContent
                } header: {
                    Text("Destination")
                }

                // Protocol section
                Section {
                    protocolContent
                } header: {
                    Text("Transfer Protocol")
                }

                // Compression settings (only for AXDP)
                if selectedProtocol == .axdp {
                    Section {
                        compressionContent
                    } header: {
                        Text("Compression")
                    }
                }

                // Advanced options
                if showAdvanced {
                    Section {
                        advancedContent
                    } header: {
                        Text("Advanced")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer with buttons
            HStack {
                Button {
                    showAdvanced.toggle()
                } label: {
                    Text(showAdvanced ? "Hide Options" : "More Options")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Send") {
                    if let session = connectedSessions[safe: selectedSessionIndex] {
                        onSend(session.remoteAddress.display, session.path.display, selectedProtocol, compressionSettings)
                    }
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(connectedSessions.isEmpty || currentProtocols.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 560, height: 620)
        .onAppear {
            analyzeFile()
        }
    }

    // MARK: - File Info Content (for Form)

    @ViewBuilder
    private func fileInfoContent(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 32))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    if let size = fileSize(url) {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let analysis = compressibilityAnalysis {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(analysis.fileCategory.rawValue)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)

        // Compressibility analysis result
        if let analysis = compressibilityAnalysis {
            compressibilityBanner(analysis)
        }
    }

    // Legacy wrapper for compatibility
    @ViewBuilder
    private func fileInfoSection(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fileInfoContent(url)
        }
    }

    @ViewBuilder
    private func compressibilityBanner(_ analysis: CompressibilityAnalysis) -> some View {
        HStack(spacing: 8) {
            Image(systemName: analysis.isCompressible ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(analysis.isCompressible ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(analysis.isCompressible ? "Good for compression" : "Low compressibility")
                    .font(.caption)
                    .fontWeight(.medium)
                Text(analysis.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(8)
        .background(analysis.isCompressible ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Destination Content (for Form)

    @ViewBuilder
    private var destinationContent: some View {
        if connectedSessions.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No connected sessions")
                        .font(.body)
                    Text("Connect to a station first, then try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Picker("Station", selection: $selectedSessionIndex) {
                ForEach(Array(connectedSessions.enumerated()), id: \.offset) { index, session in
                    HStack {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text(session.remoteAddress.display)
                            .font(.system(.body, design: .monospaced))
                    }
                    .tag(index)
                }
            }

            if let selectedSession = connectedSessions[safe: selectedSessionIndex] {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                    Text("Connected to \(selectedSession.remoteAddress.display)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    capabilityBadge(for: selectedSession.remoteAddress.display)
                }
            }
        }
    }

    // Legacy wrapper for compatibility
    @ViewBuilder
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destination")
                .font(.caption)
                .foregroundStyle(.secondary)
            destinationContent
        }
    }

    // MARK: - Protocol Content (for Form)

    /// Available protocols for the currently selected destination
    private var currentProtocols: [TransferProtocolType] {
        guard let session = connectedSessions[safe: selectedSessionIndex] else {
            return []
        }
        return availableProtocols?(session.remoteAddress.display) ?? [.axdp]
    }

    @ViewBuilder
    private var protocolContent: some View {
        if currentProtocols.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No transfer protocols available")
                        .font(.body)
                    Text("Connect to a station to discover capabilities.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if currentProtocols.count == 1 {
            // Only one protocol available, show it with badge
            LabeledContent {
                protocolBadge(currentProtocols[0])
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(currentProtocols[0].displayName)
                }
            }
            .onAppear {
                selectedProtocol = currentProtocols[0]
            }
        } else {
            // Multiple protocols available, let user choose
            Picker("Protocol", selection: $selectedProtocol) {
                ForEach(currentProtocols, id: \.self) { proto in
                    Text(proto.displayName)
                        .tag(proto)
                }
            }
            .onAppear {
                if !currentProtocols.contains(selectedProtocol) {
                    selectedProtocol = currentProtocols.first ?? .axdp
                }
            }
        }

        // Protocol features row
        HStack(spacing: 16) {
            Label {
                Text(selectedProtocol.supportsCompression ? "Compression" : "No compression")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: selectedProtocol.supportsCompression ? "archivebox.fill" : "archivebox")
                    .foregroundStyle(selectedProtocol.supportsCompression ? .blue : .secondary)
            }

            Label {
                Text(selectedProtocol.hasBuiltInAck ? "App ACKs" : "L2 only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: selectedProtocol.hasBuiltInAck ? "checkmark.shield.fill" : "shield")
                    .foregroundStyle(selectedProtocol.hasBuiltInAck ? .green : .secondary)
            }
        }
        .font(.caption)
    }

    // Legacy wrapper for compatibility
    @ViewBuilder
    private var protocolSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Protocol")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                protocolBadge(selectedProtocol)
            }
            protocolContent
        }
    }

    /// Protocol badge for display
    @ViewBuilder
    private func protocolBadge(_ proto: TransferProtocolType) -> some View {
        let color: Color = {
            switch proto {
            case .axdp: return .blue
            case .yapp: return .green
            case .sevenPlus: return .orange
            case .rawBinary: return .gray
            }
        }()

        Text(proto.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Compression Content (for Form)

    @ViewBuilder
    private var compressionContent: some View {
        Picker("Mode", selection: $compressionMode) {
            ForEach(CompressionMode.allCases, id: \.self) { mode in
                Text(mode.rawValue)
                    .tag(mode)
                    .help(mode.fullDescription)
            }
        }
        .pickerStyle(.segmented)
        .help(compressionMode.fullDescription)

        if compressionMode == .custom {
            Picker("Algorithm", selection: $selectedAlgorithm) {
                Text("LZ4 (Fast)").tag(AXDPCompression.Algorithm.lz4)
                Text("Deflate (Best ratio)").tag(AXDPCompression.Algorithm.deflate)
            }
        }

        if compressionMode != .useGlobal {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                Text("Overriding global compression settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        // Show warning if compression disabled but file is compressible
        if compressionMode == .disabled,
           let analysis = compressibilityAnalysis,
           analysis.isCompressible {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Compression disabled but file could benefit from it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Legacy wrapper for compatibility
    @ViewBuilder
    private var compressionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Compression")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if compressionMode != .useGlobal {
                    Text("Override")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
            compressionContent
        }
    }

    // MARK: - Advanced Content (for Form)

    @ViewBuilder
    private var advancedContent: some View {
        // Future: chunk size override, priority, etc.
        Text("Additional options coming soon")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
    }

    // Legacy wrapper for compatibility
    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Advanced")
                .font(.caption)
                .foregroundStyle(.secondary)
            advancedContent
        }
    }

    // MARK: - Helpers

    private var compressionSettings: TransferCompressionSettings {
        switch compressionMode {
        case .useGlobal:
            return .useGlobal
        case .enabled:
            return TransferCompressionSettings(enabledOverride: true)
        case .disabled:
            return .disabled
        case .custom:
            return .withAlgorithm(selectedAlgorithm)
        }
    }

    // MARK: - AXDP Capability Badge

    @ViewBuilder
    private func capabilityBadge(for callsign: String) -> some View {
        if let check = checkCapability {
            let status = check(callsign)
            switch status {
            case .confirmed:
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.blue)
                    Text("AXDP")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())
                .help("Station supports AXDP file transfers")

            case .pending:
                HStack(spacing: 2) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                    Text("Checking...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("Checking AXDP capability...")

            case .notSupported:
                HStack(spacing: 2) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("No AXDP")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.1))
                .clipShape(Capsule())
                .help("Station does not support AXDP. File transfers may fail.")

            case .unknown:
                HStack(spacing: 2) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Unknown")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("AXDP capability not yet checked")
            }
        } else {
            EmptyView()
        }
    }

    private func analyzeFile() {
        guard let url = selectedFileURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return
        }
        compressibilityAnalysis = CompressionAnalyzer.analyze(data, fileName: url.lastPathComponent)
    }

    private func fileSize(_ url: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    }
}

// MARK: - Incoming Transfer Request View

/// View for pending incoming transfer requests with accept/deny options
struct IncomingTransferRequestView: View {
    let request: IncomingTransferRequest
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with source callsign
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Incoming File Transfer")
                        .font(.headline)
                    Text("From \(request.sourceCallsign)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Time since received
                Text(timeAgo(request.receivedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // File info
            HStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(request.fileName)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)

                    Text(ByteCountFormatter.string(fromByteCount: Int64(request.fileSize), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Action buttons
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    onDecline()
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Decline")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onAccept()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text("Accept")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "\(seconds)s ago"
        } else if seconds < 3600 {
            return "\(seconds / 60)m ago"
        } else {
            return "\(seconds / 3600)h ago"
        }
    }
}

// MARK: - Incoming Transfer List View

/// List of pending incoming transfer requests
struct IncomingTransferListView: View {
    let requests: [IncomingTransferRequest]
    let onAccept: (UUID) -> Void
    let onDecline: (UUID) -> Void

    var body: some View {
        if !requests.isEmpty {
            VStack(spacing: 12) {
                ForEach(requests) { request in
                    IncomingTransferRequestView(
                        request: request,
                        onAccept: { onAccept(request.id) },
                        onDecline: { onDecline(request.id) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Incoming Transfer Sheet (Modal)

/// Modal sheet for incoming transfer requests with accept/deny and "always" options
struct IncomingTransferSheet: View {
    @Binding var isPresented: Bool
    let request: IncomingTransferRequest
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onAlwaysAccept: () -> Void
    let onAlwaysDeny: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Incoming File Transfer")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("From \(request.sourceCallsign)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(20)

            Divider()

            // File info
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: fileIcon(for: request.fileName))
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.fileName)
                            .font(.system(.headline, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)

                        Text(ByteCountFormatter.string(fromByteCount: Int64(request.fileSize), countStyle: .file))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Label {
                    Text("The file will be saved to your Downloads folder after transfer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                }
            }
            .padding(20)

            Divider()

            // Action buttons
            VStack(spacing: 16) {
                // Main action buttons
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        onDecline()
                        isPresented = false
                    } label: {
                        Text("Decline")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        onAccept()
                        isPresented = false
                    } label: {
                        Text("Accept")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }

                Divider()

                // "Always" options
                HStack(spacing: 16) {
                    Button {
                        onAlwaysDeny()
                        isPresented = false
                    } label: {
                        Label("Always Deny from \(request.sourceCallsign)", systemImage: "xmark.shield")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)

                    Spacer()

                    Button {
                        onAlwaysAccept()
                        isPresented = false
                    } label: {
                        Label("Always Accept from \(request.sourceCallsign)", systemImage: "checkmark.shield")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)
                }
            }
            .padding(20)
        }
        .frame(width: 450)
    }

    private func fileIcon(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "log":
            return "doc.text.fill"
        case "pdf":
            return "doc.richtext.fill"
        case "zip", "gz", "tar", "7z":
            return "doc.zipper"
        case "png", "jpg", "jpeg", "gif", "bmp":
            return "photo.fill"
        case "mp3", "wav", "aac", "flac":
            return "music.note"
        case "mp4", "mov", "avi", "mkv":
            return "film.fill"
        default:
            return "doc.fill"
        }
    }
}

// MARK: - Safe Array Access Extension

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Previews

#Preview("Transfer Row - Sending") {
    VStack {
        BulkTransferRow(
            transfer: {
                var t = BulkTransfer(
                    id: UUID(),
                    fileName: "document.pdf",
                    fileSize: 1_048_576,
                    destination: "N0CALL"
                )
                t.status = .sending
                t.bytesSent = 524_288
                t.startedAt = Date(timeIntervalSinceNow: -30)
                return t
            }(),
            onPause: {},
            onResume: {},
            onCancel: {}
        )
    }
    .padding()
    .frame(width: 400)
}

#Preview("Transfer Row - Failed") {
    VStack {
        BulkTransferRow(
            transfer: {
                var t = BulkTransfer(
                    id: UUID(),
                    fileName: "image.png",
                    fileSize: 256_000,
                    destination: "K0EPI"
                )
                t.status = .failed(reason: "No response after 10 tries (RTO 4.2s). Try a shorter path or lower packet size.")
                t.bytesSent = 64_000
                return t
            }(),
            onPause: {},
            onResume: {},
            onCancel: {}
        )
    }
    .padding()
    .frame(width: 400)
}

#Preview("Transfer List") {
    BulkTransferListView(
        transfers: [
            {
                var t = BulkTransfer(
                    id: UUID(),
                    fileName: "readme.txt",
                    fileSize: 1024,
                    destination: "N0CALL"
                )
                t.status = .sending
                t.bytesSent = 512
                t.startedAt = Date(timeIntervalSinceNow: -5)
                return t
            }(),
            {
                var t = BulkTransfer(
                    id: UUID(),
                    fileName: "photo.jpg",
                    fileSize: 50000,
                    destination: "K0EPI"
                )
                t.status = .paused
                t.bytesSent = 10000
                return t
            }(),
            {
                var t = BulkTransfer(
                    id: UUID(),
                    fileName: "archive.zip",
                    fileSize: 100000,
                    destination: "W0ABC"
                )
                t.status = .completed
                t.bytesSent = 100000
                return t
            }()
        ],
        onPause: { _ in },
        onResume: { _ in },
        onCancel: { _ in },
        onClearCompleted: {},
        onAddFile: {}
    )
    .frame(width: 500, height: 400)
}
