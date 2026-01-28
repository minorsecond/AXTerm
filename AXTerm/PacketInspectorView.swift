//
//  PacketInspectorView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI
import AppKit

struct PacketInspectorView: View {
    let packet: Packet
    var onClose: (() -> Void)?

    init(packet: Packet, onClose: (() -> Void)? = nil) {
        self.packet = packet
        self.onClose = onClose
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Packet Inspector")
                    .font(.headline)

                Spacer()

                Button("Close") {
                    onClose?()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(.bar)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    addressSection
                    frameSection
                    infoSection
                    rawSection
                }
                .padding()
            }
        }
        .frame(minWidth: 500, idealWidth: 600, minHeight: 400, idealHeight: 500)
    }

    // MARK: - Sections

    private var addressSection: some View {
        GroupBox("Addresses") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("From:")
                        .foregroundStyle(.secondary)
                    Text(packet.fromDisplay)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                GridRow {
                    Text("To:")
                        .foregroundStyle(.secondary)
                    Text(packet.toDisplay)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                if !packet.via.isEmpty {
                    GridRow {
                        Text("Via:")
                            .foregroundStyle(.secondary)
                        Text(packet.viaDisplay)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                GridRow {
                    Text("Time:")
                        .foregroundStyle(.secondary)
                    Text(packet.timestamp, style: .date) + Text(" ") + Text(packet.timestamp, style: .time)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var frameSection: some View {
        GroupBox("Frame") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Type:")
                        .foregroundStyle(.secondary)
                    Text(packet.frameType.displayName)
                        .font(.system(.body, design: .monospaced))
                }

                if let pid = packet.pid {
                    GridRow {
                        Text("PID:")
                            .foregroundStyle(.secondary)
                        Text(String(format: "0x%02X (%@)", pid, pidDescription(pid)))
                            .font(.system(.body, design: .monospaced))
                    }
                }

                GridRow {
                    Text("Length:")
                        .foregroundStyle(.secondary)
                    Text("\(packet.rawAx25.count) bytes")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var infoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Info (\(packet.info.count) bytes)")

                    Spacer()

                    if packet.infoText != nil {
                        Button("Copy") {
                            copyToClipboard(packet.infoText ?? "")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if let text = packet.infoText {
                    ScrollView {
                        Text(text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                    .padding(8)
                    .background(.background.secondary)
                    .cornerRadius(4)
                } else if packet.info.isEmpty {
                    Text("(empty)")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Text("(binary data)")
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var rawSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Raw AX.25")

                    Spacer()

                    Button("Copy Hex") {
                        copyToClipboard(hexString(packet.rawAx25))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                ScrollView {
                    Text(hexString(packet.rawAx25))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                .padding(8)
                .background(.background.secondary)
                .cornerRadius(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func pidDescription(_ pid: UInt8) -> String {
        switch pid {
        case 0x01: return "X.25 PLP"
        case 0x06: return "Compressed TCP/IP"
        case 0x07: return "Uncompressed TCP/IP"
        case 0x08: return "Segmentation Fragment"
        case 0xC3: return "TEXNET"
        case 0xC4: return "Link Quality Protocol"
        case 0xCA: return "Appletalk"
        case 0xCB: return "Appletalk ARP"
        case 0xCC: return "ARPA IP"
        case 0xCD: return "ARPA ARP"
        case 0xCE: return "FlexNet"
        case 0xCF: return "NET/ROM"
        case 0xF0: return "No Layer 3"
        case 0xFF: return "Escape"
        default: return "Unknown"
        }
    }

    private func hexString(_ data: Data) -> String {
        var result = ""
        for (index, byte) in data.enumerated() {
            if index > 0 && index % 16 == 0 {
                result += "\n"
            } else if index > 0 {
                result += " "
            }
            result += String(format: "%02X", byte)
        }
        return result
    }

    private func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

#Preview {
    PacketInspectorView(
        packet: Packet(
            from: AX25Address(call: "N0CALL", ssid: 1),
            to: AX25Address(call: "APRS"),
            via: [AX25Address(call: "WIDE1", ssid: 1, repeated: true)],
            frameType: .ui,
            pid: 0xF0,
            info: "!4903.50N/07201.75W-Test packet".data(using: .ascii)!,
            rawAx25: Data([0x82, 0xA0, 0xA4, 0xA6, 0x40, 0x40])
        )
    )
}
