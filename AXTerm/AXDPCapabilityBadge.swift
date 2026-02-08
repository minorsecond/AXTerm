//
//  AXDPCapabilityBadge.swift
//  AXTerm
//
//  Badge component for displaying AXDP capability status.
//  Shows when a station supports AXDP protocol with tooltip for details.
//

import SwiftUI

// MARK: - AXDP Badge

/// Badge showing AXDP support status for a station
struct AXDPCapabilityBadge: View {
    let capability: AXDPCapability?

    /// Compact mode for tight spaces
    var compact: Bool = false

    var body: some View {
        if let cap = capability {
            badge(for: cap)
        }
    }

    @ViewBuilder
    private func badge(for cap: AXDPCapability) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "bolt.fill")
                .font(.system(size: compact ? 8 : 10))

            if !compact {
                Text("AXDP")
                    .font(.system(size: 9, weight: .semibold))
            }

            if cap.features.contains(.compression) && !compact {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 8))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, 2)
        .background(badgeColor(for: cap))
        .clipShape(Capsule())
        .help(tooltipText(for: cap))
    }

    private func badgeColor(for cap: AXDPCapability) -> Color {
        // Color based on feature richness
        let featureCount = [
            cap.features.contains(.sack),
            cap.features.contains(.resume),
            cap.features.contains(.compression),
            cap.features.contains(.extendedMetadata)
        ].filter { $0 }.count

        if featureCount >= 3 {
            return .green
        } else if featureCount >= 1 {
            return .blue
        } else {
            return .gray
        }
    }

    private func tooltipText(for cap: AXDPCapability) -> String {
        var lines: [String] = []

        lines.append("AXDP Protocol v\(cap.protoMin)-\(cap.protoMax)")
        lines.append("")

        // Features
        lines.append("Features:")
        if cap.features.contains(.sack) {
            lines.append("  • Selective ACK (faster retransmits)")
        }
        if cap.features.contains(.resume) {
            lines.append("  • Transfer Resume")
        }
        if cap.features.contains(.compression) {
            lines.append("  • Compression")
        }
        if cap.features.contains(.extendedMetadata) {
            lines.append("  • Extended Metadata")
        }
        if cap.features.isEmpty {
            lines.append("  • Basic only")
        }

        // Compression algorithms
        if !cap.compressionAlgos.isEmpty && cap.features.contains(.compression) {
            lines.append("")
            lines.append("Compression:")
            for algo in cap.compressionAlgos {
                lines.append("  • \(algo.displayName)")
            }
        }

        // Limits
        lines.append("")
        lines.append("Limits:")
        lines.append("  • Max chunk: \(cap.maxChunkLen) bytes")
        lines.append("  • Max decompressed: \(cap.maxDecompressedLen) bytes")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Inline Feature Badges

/// Shows individual feature badges inline
struct AXDPFeatureBadges: View {
    let capability: AXDPCapability

    var body: some View {
        HStack(spacing: 4) {
            if capability.features.contains(.compression) {
                featureBadge("C", color: .green, help: "Compression supported")
            }
            if capability.features.contains(.sack) {
                featureBadge("S", color: .blue, help: "Selective ACK")
            }
            if capability.features.contains(.resume) {
                featureBadge("R", color: .purple, help: "Transfer Resume")
            }
            if capability.features.contains(.extendedMetadata) {
                featureBadge("M", color: .orange, help: "Extended Metadata")
            }
        }
    }

    @ViewBuilder
    private func featureBadge(_ letter: String, color: Color, help: String) -> some View {
        Text(letter)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(help)
    }
}

// MARK: - Capability Detail View

/// Detailed view of AXDP capabilities (for inspector/popover)
struct AXDPCapabilityDetailView: View {
    let capability: AXDPCapability
    let peerCallsign: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.green)
                Text("AXDP Capabilities")
                    .font(.headline)
                Spacer()
                Text("v\(capability.protoMin)-\(capability.protoMax)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Peer info
            HStack {
                Text("Peer:")
                    .foregroundStyle(.secondary)
                Text(peerCallsign)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
            }

            // Features section
            VStack(alignment: .leading, spacing: 6) {
                Text("Features")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                featureRow("Selective ACK", enabled: capability.features.contains(.sack),
                           description: "Faster recovery from lost packets")
                featureRow("Transfer Resume", enabled: capability.features.contains(.resume),
                           description: "Resume interrupted transfers")
                featureRow("Compression", enabled: capability.features.contains(.compression),
                           description: "Reduce data over the air")
                featureRow("Extended Metadata", enabled: capability.features.contains(.extendedMetadata),
                           description: "Rich file information")
            }

            // Compression algorithms
            if capability.features.contains(.compression) && !capability.compressionAlgos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Compression Algorithms")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    HStack(spacing: 8) {
                        ForEach(capability.compressionAlgos, id: \.self) { algo in
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                                Text(algo.displayName)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            // Limits
            VStack(alignment: .leading, spacing: 4) {
                Text("Negotiated Limits")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                HStack {
                    limitBadge("Chunk", value: "\(capability.maxChunkLen)B")
                    limitBadge("Max Decompress", value: "\(capability.maxDecompressedLen)B")
                }
            }
        }
        .padding()
        .frame(width: 320)
    }

    @ViewBuilder
    private func featureRow(_ name: String, enabled: Bool, description: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(enabled ? .green : .secondary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.caption)
                    .fontWeight(enabled ? .medium : .regular)
                    .foregroundStyle(enabled ? .primary : .secondary)
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func limitBadge(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Previews

#Preview("AXDP Badge - Full") {
    VStack(spacing: 12) {
        AXDPCapabilityBadge(capability: .defaultLocal())
        AXDPCapabilityBadge(capability: AXDPCapability(
            protoMin: 1, protoMax: 1,
            features: [.sack],
            compressionAlgos: [],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        ))
        AXDPCapabilityBadge(capability: nil)
    }
    .padding()
}

#Preview("AXDP Badge - Compact") {
    HStack {
        Text("N0CALL")
        AXDPCapabilityBadge(capability: .defaultLocal(), compact: true)
    }
    .padding()
}

#Preview("Feature Badges") {
    AXDPFeatureBadges(capability: .defaultLocal())
        .padding()
}

#Preview("Capability Detail") {
    AXDPCapabilityDetailView(
        capability: .defaultLocal(),
        peerCallsign: "N0CALL-5"
    )
}
