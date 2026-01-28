//
//  PacketInspectorView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PacketInspectorView: View {
    let packet: Packet
    var isPinned: Bool
    var onTogglePin: (() -> Void)?
    var onFilterStation: ((String) -> Void)?
    var onClose: (() -> Void)?

    private enum PayloadViewMode: String, CaseIterable {
        case hex = "Hex"
        case ascii = "ASCII"
    }

    private enum InspectorTab: String, CaseIterable {
        case summary = "Summary"
        case payload = "Payload"
        case raw = "Raw"
    }

    init(
        packet: Packet,
        isPinned: Bool = false,
        onTogglePin: (() -> Void)? = nil,
        onFilterStation: ((String) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.packet = packet
        self.isPinned = isPinned
        self.onTogglePin = onTogglePin
        self.onFilterStation = onFilterStation
        self.onClose = onClose
    }

    @Environment(\.dismiss) private var dismiss
    @State private var payloadViewMode: PayloadViewMode = .hex
    @State private var selectedTab: InspectorTab = .summary
    @State private var renderFullPayload: Bool = false
    @State private var renderFullRaw: Bool = false
    @State private var findQuery: String = ""
    @FocusState private var isFindFocused: Bool
    @State private var copyFeedback: CopyFeedback?

    private let payloadPreviewLimit: Int = 2048
    private let rawPreviewLimit: Int = 2048

    private enum CopyFeedback: Equatable {
        case info
        case infoHex
        case ascii
        case json
        case rawHex
        case frequency(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            Picker("Inspector Tab", selection: $selectedTab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .summary:
                        summaryTab
                    case .payload:
                        payloadTab
                    case .raw:
                        rawTab
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 420, idealHeight: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(packet.fromDisplay)
                        .font(.title3.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(packet.toDisplay)
                        .font(.title3.weight(.semibold))
                }

                HStack(spacing: 10) {
                    Text(packet.frameType.displayName)
                        .font(.subheadline.weight(.medium))
                    Text(packet.frameType.icon)
                    Text(packet.timestamp, style: .date)
                        .foregroundStyle(.secondary)
                    Text(packet.timestamp, style: .time)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            Spacer()

            Button {
                onTogglePin?()
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.bordered)
            .help(isPinned ? "Unpin Packet" : "Pin Packet")

            Button("Close") {
                onClose?()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Tabs

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            addressSection
            pathSection
            frameSection
            actionSection
            detectionSection
        }
    }

    private var payloadTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            payloadToolbar
            payloadFindBar
            payloadContent
        }
    }

    private var rawTab: some View {
        GroupBox("Raw AX.25") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(packet.rawAx25.count) bytes")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Copy Hex") {
                        performCopy(PayloadFormatter.hexString(packet.rawAx25), feedback: .rawHex)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    copyBadge(for: .rawHex)
                }

                if packet.rawAx25.count > rawPreviewLimit && !renderFullRaw {
                    HStack(spacing: 12) {
                        Label("Showing first \(rawPreviewLimit) bytes", systemImage: "eye")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Render full") {
                            renderFullRaw = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                ScrollView {
                    Text(rawText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(.background.secondary)
                .cornerRadius(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Summary Sections

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

    private var pathSection: some View {
        GroupBox("Path") {
            VStack(alignment: .leading, spacing: 8) {
                if packet.via.isEmpty {
                    Text("Direct (no digipeaters)")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(packet.via) { address in
                            PathChip(address: address)
                        }
                    }
                }

                if !packet.via.isEmpty {
                    Text("Heard via: \(packet.viaDisplay)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let repeated = packet.via.filter { $0.repeated }
                    if !repeated.isEmpty {
                        Text("Repeated: \(repeated.map { $0.display }.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

    private var actionSection: some View {
        GroupBox("Actions") {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Button("Copy Info") {
                        performCopy(packet.infoText ?? "", feedback: .info)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(packet.infoText == nil)

                    copyBadge(for: .info)
                }

                HStack(spacing: 6) {
                    Button("Copy Hex") {
                        performCopy(PayloadFormatter.hexString(packet.info), feedback: .infoHex)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    copyBadge(for: .infoHex)
                }

                HStack(spacing: 6) {
                    Button("Copy ASCII") {
                        performCopy(PayloadFormatter.asciiString(packet.info), feedback: .ascii)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    copyBadge(for: .ascii)
                }

                HStack(spacing: 6) {
                    Button("Copy JSON") {
                        if let json = PacketExport(packet: packet).jsonString() {
                            performCopy(json, feedback: .json)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    copyBadge(for: .json)
                }

                Button("Save JSON...") {
                    saveJSON()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var detectionSection: some View {
        let summary = payloadTokenSummary
        return GroupBox("Detected") {
            VStack(alignment: .leading, spacing: 10) {
                if summary.isEmpty {
                    Text("No tokens detected.")
                        .foregroundStyle(.secondary)
                }

                if !summary.callsigns.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Callsigns")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(summary.callsigns, id: \.self) { callsign in
                                Button(callsign) {
                                    onFilterStation?(callsign)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }

                if !summary.frequencies.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Frequencies")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(summary.frequencies, id: \.self) { freq in
                                HStack(spacing: 6) {
                                    Button("Copy \(freq) MHz") {
                                        performCopy(freq, feedback: .frequency(freq))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    copyBadge(for: .frequency(freq))
                                }
                            }
                        }
                    }
                }

                if !summary.urls.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Links")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(summary.urls, id: \.self) { url in
                            Text(url)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Payload Tab

    private var payloadToolbar: some View {
        GroupBox("Payload") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Payload View", selection: $payloadViewMode) {
                        ForEach(PayloadViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)

                    Spacer()

                    HStack(spacing: 6) {
                        Button("Copy Info") {
                            performCopy(packet.infoText ?? "", feedback: .info)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(packet.infoText == nil)

                        copyBadge(for: .info)
                    }

                    HStack(spacing: 6) {
                        Button("Copy Hex") {
                            performCopy(PayloadFormatter.hexString(packet.info), feedback: .infoHex)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        copyBadge(for: .infoHex)
                    }

                    HStack(spacing: 6) {
                        Button("Copy ASCII") {
                            performCopy(PayloadFormatter.asciiString(packet.info), feedback: .ascii)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        copyBadge(for: .ascii)
                    }
                }

                HStack {
                    Text("\(packet.info.count) bytes")
                        .foregroundStyle(.secondary)

                    Spacer()

                    if packet.info.count > payloadPreviewLimit && !renderFullPayload {
                        Button("Render full") {
                            renderFullPayload = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var payloadFindBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in payload", text: $findQuery)
                .textFieldStyle(.roundedBorder)
                .focused($isFindFocused)

            Button("Find") {
                isFindFocused = true
            }
            .keyboardShortcut("f", modifiers: [.command])
        }
        .frame(maxHeight: 260)
        .padding(8)
        .background(.background.secondary)
        .cornerRadius(6)
    }

    private var payloadContent: some View {
        ScrollView {
            if findQuery.isEmpty {
                Text(payloadText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(highlightedPayload)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: 260)
        .padding(8)
        .background(.background.secondary)
        .cornerRadius(6)
    }

    // MARK: - Helpers

    private var payloadTokenSummary: PayloadTokenSummary {
        guard let text = packet.infoText, !text.isEmpty else {
            return PayloadTokenSummary(callsigns: [], frequencies: [], urls: [])
        }
        return PayloadTokenExtractor.summarize(text: text)
    }

    private var payloadText: String {
        let data = payloadData
        switch payloadViewMode {
        case .hex:
            return PayloadFormatter.hexString(data)
        case .ascii:
            return PayloadFormatter.asciiString(data)
        }
    }

    private var highlightedPayload: AttributedString {
        PayloadSearchHighlighter.highlight(text: payloadText, query: findQuery)
    }

    private var payloadData: Data {
        if renderFullPayload {
            return packet.info
        }
        return packet.info.prefix(payloadPreviewLimit)
    }

    private var rawText: String {
        let data = renderFullRaw ? packet.rawAx25 : packet.rawAx25.prefix(rawPreviewLimit)
        return PayloadFormatter.hexString(data)
    }

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

    private func performCopy(_ string: String, feedback: CopyFeedback) {
        ClipboardWriter.copy(string)
        showCopyFeedback(feedback)
    }

    private func showCopyFeedback(_ feedback: CopyFeedback) {
        withAnimation(.easeInOut(duration: 0.12)) {
            copyFeedback = feedback
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copyFeedback == feedback {
                withAnimation(.easeInOut(duration: 0.12)) {
                    copyFeedback = nil
                }
            }
        }
    }

    @ViewBuilder
    private func copyBadge(for feedback: CopyFeedback) -> some View {
        if copyFeedback == feedback {
            Text("Copied")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }

    private func saveJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "packet-\(packet.id.uuidString.prefix(8)).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try PacketExport(packet: packet).writeJSON(to: url)
            } catch {
                NSSound.beep()
            }
        }
    }
}

private struct PathChip: View {
    let address: AX25Address

    var body: some View {
        Text(address.display)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(address.repeated ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15))
            )
            .foregroundStyle(address.repeated ? .primary : .secondary)
    }
}

private enum PayloadSearchHighlighter {
    static func highlight(text: String, query: String) -> AttributedString {
        guard !query.isEmpty else { return AttributedString(text) }

        let nsText = text as NSString
        let lowerText = text.lowercased() as NSString
        let lowerQuery = query.lowercased()
        let result = NSMutableAttributedString(string: text)

        var searchRange = NSRange(location: 0, length: nsText.length)
        while true {
            let foundRange = lowerText.range(of: lowerQuery, options: [], range: searchRange)
            if foundRange.location == NSNotFound {
                break
            }
            result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: foundRange)
            let nextLocation = foundRange.location + foundRange.length
            if nextLocation >= nsText.length {
                break
            }
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        return AttributedString(result)
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
            info: "CQ CQ http://example.com 145.050 N0CALL".data(using: .ascii) ?? Data(),
            rawAx25: Data([0x82, 0xA0, 0xA4, 0xA6, 0x40, 0x40])
        )
    )
}
