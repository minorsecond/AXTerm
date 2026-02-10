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
    @Binding var clearedAt: Date?

    @State private var autoScroll = true
    @State private var isUserNearBottom = true
    @State private var scrollViewHeight: CGFloat = 0
    @State private var showUndoClear = false
    @State private var undoClearTask: Task<Void, Never>?
    @State private var previousClearedAt: Date?
    @State private var scrollToBottomToken = 0

    /// Chunks filtered by clear timestamp
    private var filteredChunks: [RawChunk] {
        guard let cutoff = clearedAt else { return chunks }
        return chunks.filter { $0.timestamp > cutoff }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                HStack {
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.checkbox)

                    Spacer()

                    Text("\(filteredChunks.count) chunks")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    Button("Clear") {
                        clearRaw()
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
                                ForEach(filteredChunks) { chunk in
                                    RawChunkView(chunk: chunk)
                                        .id(chunk.id)
                                }
                            }
                            Color.clear
                                .frame(height: 10)
                                .id("bottom")
                                .onAppear { isUserNearBottom = true }
                                .onDisappear { isUserNearBottom = false }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: filteredChunks.count) { _, _ in
                        guard autoScroll, isUserNearBottom else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: scrollToBottomToken) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onAppear {
                        scrollToBottomToken += 1
                    }
                }
                .background(.background)
            }

            // Undo clear banner
            if showUndoClear {
                VStack {
                    undoClearBanner
                        .padding(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                // Transition needs to be applied to the container or item
            }

            // Jump to Bottom Button
            if !isUserNearBottom {
                Button {
                    isUserNearBottom = true
                    autoScroll = true
                    scrollToBottomToken += 1
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundStyle(.secondary, .regularMaterial)
                        .background(Circle().fill(.background))
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .padding([.bottom, .trailing], 20)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showUndoClear)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isUserNearBottom)
    }

    private var groupedChunks: [DayGroupedSection<RawChunk>] {
        DayGrouping.group(items: filteredChunks, date: { $0.timestamp })
    }

    // MARK: - Clear Actions

    private func clearRaw() {
        undoClearTask?.cancel()
        previousClearedAt = clearedAt
        clearedAt = Date()
        showUndoClear = true

        undoClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled {
                withAnimation {
                    showUndoClear = false
                    previousClearedAt = nil
                }
            }
        }
    }

    private func undoClear() {
        undoClearTask?.cancel()
        clearedAt = previousClearedAt
        previousClearedAt = nil
        withAnimation {
            showUndoClear = false
        }
    }

    @ViewBuilder
    private var undoClearBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
            .foregroundStyle(.secondary)
            
            Text("Raw data cleared")
            .font(.callout)
            .foregroundStyle(.secondary)
            
            Button("Undo") {
                undoClear()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}

nonisolated private struct RawScrollBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
