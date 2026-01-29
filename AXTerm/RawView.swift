//
//  RawView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI
import AppKit

struct RawView: View {
    let chunks: [RawChunk]
    let showDaySeparators: Bool
    let onClear: () -> Void

    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Spacer()

                Text("\(chunks.count) chunks")
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
                        if showDaySeparators {
                            ForEach(groupedChunks) { section in
                                DaySeparatorView(date: section.date)
                                    .padding(.vertical, 4)

                                ForEach(section.items) { chunk in
                                    RawChunkView(chunk: chunk)
                                        .id(chunk.id)
                                }
                            }
                        } else {
                            ForEach(chunks) { chunk in
                                RawChunkView(chunk: chunk)
                                    .id(chunk.id)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chunks.count) { _, _ in
                    guard autoScroll, let lastChunk = chunks.last else { return }
                    Task { @MainActor in
                        // Avoid triggering scroll/layout during the same update transaction.
                        await Task.yield()
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(lastChunk.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(.background)
        }
    }

    private var groupedChunks: [DayGroupedSection<RawChunk>] {
        DayGrouping.group(items: chunks, date: { $0.timestamp })
    }
}

struct RawChunkView: View {
    let chunk: RawChunk

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(chunk.timestampString)
                    .foregroundStyle(.secondary)

                Text("[\(chunk.data.count) bytes]")
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    copyToPasteboard(chunk.hex)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Text(chunk.hex)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
        }
        .padding(8)
        .background(.background.secondary)
        .cornerRadius(6)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
