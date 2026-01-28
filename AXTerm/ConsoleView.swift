//
//  ConsoleView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

struct ConsoleView: View {
    let lines: [ConsoleLine]
    let onClear: () -> Void

    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Spacer()

                Text("\(lines.count) lines")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                Button("Clear") {
                    onClear()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(lines) { line in
                            ConsoleLineView(line: line)
                                .id(line.id)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lines.count) { _, _ in
                    if autoScroll, let lastLine = lines.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(lastLine.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(.background)
        }
    }
}

struct ConsoleLineView: View {
    let line: ConsoleLine
    private let callsignSaturation: Double = 0.35
    private let callsignBrightness: Double = 0.75

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.timestampString)
                .foregroundStyle(.secondary)

            if let from = line.from {
                Text(from)
                    .fontWeight(.semibold)
                    .foregroundStyle(callsignColor(for: from))

                if let to = line.to {
                    Text("→")
                        .foregroundStyle(.secondary)

                    Text(to)
                        .fontWeight(.semibold)
                        .foregroundStyle(callsignColor(for: to))
                }

                Text(":")
                    .foregroundStyle(.secondary)
            }

            Text(line.text)
                .foregroundStyle(messageColor)
                .textSelection(.enabled)
        }
        .font(.system(.body, design: .monospaced))
    }

    private var messageColor: Color {
        switch line.kind {
        case .system: return .secondary
        case .error: return .red
        case .packet: return .primary
        }
    }

    private func callsignColor(for callsign: String) -> Color {
        guard line.kind == .packet else { return messageColor }
        let hash = abs(callsign.hashValue)
        let hue = Double(hash % 256) / 255.0
        return Color(hue: hue, saturation: callsignSaturation, brightness: callsignBrightness)
    }
}
