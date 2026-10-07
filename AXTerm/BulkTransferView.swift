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
        // A running transfer is redrawn every second, so a receiver that
        // stops hearing from the sender says so even when nothing else on
        // screen changes.
        if isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                rowContent(now: context.date)
            }
        } else {
            rowContent(now: Date())
        }
    }

    @ViewBuilder
    private func rowContent(now: Date) -> some View {
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
                // One line, shortened in the middle so the extension stays:
                // on a phone the name broke mid-word ("t20k_bin.bi" / "n").
                Text(transfer.fileName)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(transfer.fileName)

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
                statusBadge(now: now)

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

                    // Throughput (data rate). Hidden while paused or while
                    // waiting for the sender: there is no live rate then.
                    let showsRate = transfer.showsLiveRate(now: now)
                    if showsRate, transfer.throughputBytesPerSecond(now: now) > 0 {
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
                    if showsRate, transfer.airThroughputBytesPerSecond > 0 {
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
                    if showsRate, let eta = transfer.estimatedSecondsRemaining(now: now) {
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

            // A received file: where it went and what to do with it. An
            // incomplete text download is failed but saved, so it gets the
            // same actions under its failure reason.
            if transfer.direction == .inbound, showsSavedFile,
               let path = transfer.savedFilePath {
                ReceivedFileActions(path: path)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            // Failure explanation (if failed). A decline is the other
            // station's choice, so it is said plainly, not in red.
            if case .failed(let reason) = transfer.status {
                HStack(spacing: 4) {
                    Image(systemName: transfer.wasDeclined ? "hand.raised" : "exclamationmark.triangle.fill")
                        .foregroundStyle(transfer.wasDeclined ? Color.secondary : Color.red)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(transfer.wasDeclined ? Color.secondary : Color.red)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Whether the row offers the saved file: a completed one, or a failed
    /// one that was saved anyway (an incomplete text download).
    private var showsSavedFile: Bool {
        switch transfer.status {
        case .completed, .failed: return true
        default: return false
        }
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
            case .text: return .teal
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
            detailRow("Chunks", transfer.chunkProgressText,
                      help: transfer.direction == .inbound
                        ? "Chunks received out of the total."
                        : "Chunks sent out of the total. AXDP confirms the whole file at the end rather than each chunk, so they count as confirmed once the receiver reports the file arrived intact.")

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
        ByteCount.string(Int64(bytes))
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 0.1 {
            // Show milliseconds for very small durations (< 100ms)
            let ms = Int(seconds * 1000)
            return "\(ms)ms"
        } else if seconds < 60 {
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
        LinkRateText.bitsPerSecond(bitsPerSecond)
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
        let sent = ByteCount.string(Int64(transfer.bytesSent))
        let total = ByteCount.string(Int64(targetSize))

        // If compressed and different from original, show both
        if transfer.compressionUsed && targetSize != transfer.fileSize {
            let originalFormatted = ByteCount.string(Int64(transfer.fileSize))
            return "\(sent) / \(total) (\(originalFormatted) uncompressed)"
        }
        return "\(sent) / \(total)"
    }

    private var throughputText: String {
        let bps = transfer.throughputBytesPerSecond
        let formatted = ByteCount.string(Int64(bps))
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
    private func statusBadge(now: Date) -> some View {
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
            if let quiet = transfer.secondsWaitingForSender(now: now) {
                // The sender may have paused; AXDP and YAPP have no way to
                // say so, so this is what the receiver can see.
                Label("Waiting for \(transfer.destination)", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(Self.waitingHelp(peer: transfer.destination, quietSeconds: quiet))
            } else if transfer.direction == .inbound {
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
            Label("Canceled", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            if transfer.wasDeclined {
                Label("Declined", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Failed", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// Tooltip for a receiver that has stopped hearing from the sender.
    static func waitingHelp(peer: String, quietSeconds: TimeInterval) -> String {
        "Nothing has arrived from \(peer) for \(Int(quietSeconds)) s. "
            + "The sender may have paused the transfer, or the link may be struggling. "
            + "This changes back to Receiving when data arrives."
    }

    private var backgroundColor: Color {
        switch transfer.status {
        case .failed where transfer.wasDeclined:
            return Color.secondary.opacity(0.1)
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
    /// One identity for a transfer's whole life. Keyed on its status and
    /// chunk count, SwiftUI made a new row for every chunk and the row's
    /// state went with it: details the operator had opened closed each time
    /// (smoke run 2026-10-03-1, issue 112). The row still redraws from the
    /// new value, and a running one every second besides.
    static func rowIdentity(for transfer: BulkTransfer) -> UUID {
        transfer.id
    }

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

    /// Offers waiting for this operator, shown with Accept and Decline so
    /// one that was swiped away, or arrived while the prompt showed another,
    /// can still be answered here.
    private var visibleIncomingRequests: [IncomingTransferRequest] {
        suppressIncomingRequests ? [] : pendingIncomingTransfers
    }

    /// Every transfer, except the inbound rows for offers listed above: the
    /// offer card already stands for them.
    private var visibleTransfers: [BulkTransfer] {
        let offered = Set(visibleIncomingRequests.map(\.id))
        return transfers.filter { !offered.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("File Transfers")
                    .font(.headline)

                Spacer()

                if !completedTransfers.isEmpty {
                    Button("Clear Finished") {
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
                        .font(.headline)

                    Text(TransferCopy.emptyStateHint(for: TransferDevice.current))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(TransferCopy.receivedFilesNote(for: TransferDevice.current))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if !visibleIncomingRequests.isEmpty {
                            Section {
                                ForEach(visibleIncomingRequests) { request in
                                    IncomingTransferRequestView(
                                        request: request,
                                        onAccept: { onAcceptIncoming?(request.id) },
                                        onDecline: { onDeclineIncoming?(request.id) })
                                }
                            } header: {
                                SectionHeader(title: "Offered to You", count: visibleIncomingRequests.count)
                            }
                        }

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
                                    .id(Self.rowIdentity(for: transfer))
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
                                    .id(Self.rowIdentity(for: transfer))
                                }
                            } header: {
                                // Finished rather than Completed: canceled, declined and
                                // failed transfers are listed here too.
                                SectionHeader(title: "Finished", count: completedTransfers.count)
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
            case .pending, .awaitingAcceptance, .sending, .paused, .awaitingCompletion:
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

/// The words on the Send File sheet's AXDP badge and its tooltip.
struct SendFileCapabilityBadgeText {
    let label: String
    let help: String

    init(status: SessionCoordinator.CapabilityStatus, callsign: String) {
        switch status {
        case .confirmed:
            label = "AXDP"
            help = "Station supports AXDP file transfers"
        case .pending:
            label = "Checking\u{2026}"
            help = "Asking \(callsign) whether it speaks AXDP, up to \(AXDPCapabilityProbe.maxAttempts) times. "
                + "YAPP can be used while it waits."
        case .notSupported:
            label = "No answer"
            help = "\(callsign) did not answer the AXDP check after \(AXDPCapabilityProbe.maxAttempts) tries. "
                + "Send by YAPP, which most packet software understands."
        case .unknown:
            label = "Unknown"
            help = "AXDP capability not yet checked"
        }
    }
}

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

    /// Optional closure to start an AXDP check for a station nobody has asked yet
    var requestCapabilityCheck: ((String) -> Void)?

    @State private var selectedSessionIndex: Int = 0
    @State private var compressibilityAnalysis: CompressibilityAnalysis?
    @State private var compressionMode: CompressionMode = .useGlobal
    @State private var selectedAlgorithm: AXDPCompression.Algorithm = .lz4
    @State private var selectedProtocol: TransferProtocolType = .axdp

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

            }
            .formStyle(.grouped)

            Divider()

            // Footer with buttons
            // "More Options" used to sit here and open a placeholder
            // ("Additional options coming soon"); it is gone until there
            // are options to show (issue 107).
            HStack {
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
        .modifier(PlatformSheetFrame(macWidth: 560, macHeight: 620))
        .onAppear {
            analyzeFile()
            requestCheckForSelectedStation()
        }
        .onChange(of: selectedSessionIndex) { _, _ in
            requestCheckForSelectedStation()
        }
    }

    /// Ask the selected station about AXDP if nobody has, so the badge does
    /// not sit on "Unknown".
    private func requestCheckForSelectedStation() {
        guard let session = connectedSessions[safe: selectedSessionIndex] else { return }
        requestCapabilityCheck?(session.remoteAddress.display)
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
                        Text(ByteCount.string(Int64(size)))
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
            case .text: return .teal
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
            let text = SendFileCapabilityBadgeText(status: status, callsign: callsign)
            switch status {
            case .confirmed:
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.blue)
                    Text(text.label)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())
                .help(text.help)

            case .pending:
                HStack(spacing: 2) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                    Text(text.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help(text.help)

            case .notSupported:
                HStack(spacing: 2) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(text.label)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.1))
                .clipShape(Capsule())
                .help(text.help)

            case .unknown:
                HStack(spacing: 2) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Text(text.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help(text.help)
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

                    Text(TransferCopy.offerSummary(request))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

                        Text(TransferCopy.offerSummary(request))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Label {
                    Text(TransferCopy.saveLocation(for: TransferDevice.current))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

                // "Always" options. Side by side where they fit; stacked on
                // a phone, where the two labels ran into each other.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        alwaysDenyButton(fullWidth: false)
                        Spacer()
                        alwaysAcceptButton(fullWidth: false)
                    }
                    VStack(spacing: 10) {
                        alwaysAcceptButton(fullWidth: true)
                        alwaysDenyButton(fullWidth: true)
                    }
                }
            }
            .padding(20)
        }
        .modifier(sheetFrame)
    }

    private var sheetFrame: PlatformSheetFrame {
        #if os(iOS)
        PlatformSheetFrame(macWidth: 450, macHeight: nil, detents: [.medium, .large])
        #else
        PlatformSheetFrame(macWidth: 450, macHeight: nil)
        #endif
    }

    // Bordered buttons rather than caption-sized text: as text they were
    // well under a comfortable tap target on a phone (issue 107).
    private func alwaysDenyButton(fullWidth: Bool) -> some View {
        Button {
            onAlwaysDeny()
            isPresented = false
        } label: {
            Label("Always Deny from \(request.sourceCallsign)", systemImage: "xmark.shield")
                .font(.subheadline)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private func alwaysAcceptButton(fullWidth: Bool) -> some View {
        Button {
            onAlwaysAccept()
            isPresented = false
        } label: {
            Label("Always Accept from \(request.sourceCallsign)", systemImage: "checkmark.shield")
                .font(.subheadline)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .tint(.green)
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
