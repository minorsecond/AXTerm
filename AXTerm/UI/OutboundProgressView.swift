//
//  OutboundProgressView.swift
//  AXTerm
//
//  Sender UI: progressive highlighting of outbound message (pending → sent → acked).
//

import SwiftUI

/// Shows an outbound message with progressive highlighting as chunks are sent and ACKed
struct OutboundProgressView: View {
    let progress: OutboundMessageProgress
    let sourceCall: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Callsign header
            HStack(spacing: 6) {
                Text(sourceCall)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text("→")
                    .foregroundStyle(.tertiary)
                Text(progress.destination)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                if progress.hasAcks {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    progressBadge
                }
            }
            .font(.system(size: 11, design: .monospaced))

            // Message text with progressive highlighting
            highlightedMessageText
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var progressBadge: some View {
        if progress.isComplete {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("Delivered")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            }
        } else if progress.hasAcks && progress.bytesAcked > 0 {
            Text("\(progress.bytesAcked)/\(progress.totalBytes) acked")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        } else if progress.bytesSent > 0 {
            Text("Sending…")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            Text("Queued")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    /// Message text with three visual states: acked (green tint), sent (blue tint), pending (dim)
    private var highlightedMessageText: some View {
        let text = progress.text
        let totalUTF8 = text.utf8.count

        // Map payload byte ranges to text byte ranges (proportional; payload may include AXDP header)
        let totalBytes = max(1, progress.totalBytes)
        let ackedBytes = progress.ackedEndIndex
        let sentBytes = progress.sentEndIndex
        let ackedEnd = (ackedBytes * totalUTF8) / totalBytes
        let sentEnd = (sentBytes * totalUTF8) / totalBytes

        // Build attributed spans: [0, ackedEnd) green, [ackedEnd, sentEnd) blue, [sentEnd, total) dim
        return Text(buildAttributedText(text: text, utf8Count: totalUTF8, ackedEnd: ackedEnd, sentEnd: sentEnd))
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buildAttributedText(text: String, utf8Count: Int, ackedEnd: Int, sentEnd: Int) -> AttributedString {
        var result = AttributedString()

        if utf8Count == 0 {
            result = AttributedString(text)
            return result
        }

        // Walk string by UTF-8 byte offset to apply styles
        var offset = 0
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            let char = text[currentIndex]
            let charUTF8Len = String(char).utf8.count
            let nextOffset = offset + charUTF8Len

            var span = AttributedString(String(char))
            if offset < ackedEnd {
                span.foregroundColor = .green.opacity(0.9)
            } else if offset < sentEnd {
                span.foregroundColor = Color.accentColor.opacity(0.9)
            } else {
                span.foregroundColor = .secondary.opacity(0.8)
            }
            result.append(span)

            offset = nextOffset
            currentIndex = text.index(after: currentIndex)
        }

        return result
    }
}
