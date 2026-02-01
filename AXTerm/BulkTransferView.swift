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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack {
                // File icon
                Image(systemName: fileIcon)
                    .foregroundStyle(.secondary)

                // File name
                Text(transfer.fileName)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)

                Spacer()

                // Status badge
                statusBadge

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

                // Stats row
                HStack {
                    // Bytes progress
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Throughput
                    if transfer.throughputBytesPerSecond > 0 {
                        Text(throughputText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // ETA
                    if let eta = transfer.estimatedSecondsRemaining {
                        Text(etaText(eta))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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

    // MARK: - Computed Properties

    private var isActive: Bool {
        switch transfer.status {
        case .pending, .sending, .paused:
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
        let sent = ByteCountFormatter.string(
            fromByteCount: Int64(transfer.bytesSent),
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(transfer.fileSize),
            countStyle: .file
        )
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
            Label("Queued", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .sending:
            Label("Sending", systemImage: "arrow.up.circle")
                .font(.caption)
                .foregroundStyle(.blue)
        case .paused:
            Label("Paused", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.orange)
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
    let onPause: (UUID) -> Void
    let onResume: (UUID) -> Void
    let onCancel: (UUID) -> Void
    let onClearCompleted: () -> Void
    let onAddFile: () -> Void

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
            if transfers.isEmpty {
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
        transfers.filter { transfer in
            switch transfer.status {
            case .pending, .sending, .paused:
                return true
            default:
                return false
            }
        }
    }

    private var completedTransfers: [BulkTransfer] {
        transfers.filter { transfer in
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

/// Sheet for initiating a new file transfer
struct SendFileSheet: View {
    @Binding var isPresented: Bool
    let selectedFileURL: URL?
    let onSend: (String, String) -> Void

    @State private var destinationCall: String = ""
    @State private var digiPath: String = ""

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Send File")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
            }

            Divider()

            // File info
            if let url = selectedFileURL {
                HStack {
                    Image(systemName: "doc")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent)
                            .font(.headline)

                        if let size = fileSize(url) {
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(size),
                                countStyle: .file
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding()
                .background(.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Destination
            VStack(alignment: .leading, spacing: 4) {
                Text("Destination Callsign")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("N0CALL", text: $destinationCall)
                    .textFieldStyle(.roundedBorder)
                    .textCase(.uppercase)
            }

            // Digi path
            VStack(alignment: .leading, spacing: 4) {
                Text("Digipeater Path (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("WIDE1-1,WIDE2-1", text: $digiPath)
                    .textFieldStyle(.roundedBorder)
                    .textCase(.uppercase)
            }

            Spacer()

            // Send button
            HStack {
                Spacer()
                Button("Send") {
                    onSend(destinationCall, digiPath)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(destinationCall.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
    }

    private func fileSize(_ url: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
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
