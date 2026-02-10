//
//  ConsoleView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

struct ConsoleView: View {
    let lines: [ConsoleLine]
    let showDaySeparators: Bool
    @Binding var clearedAt: Date?

    @State private var autoScroll = true
    @State private var isUserNearBottom = true
    @State private var scrollViewHeight: CGFloat = 0
    @State private var showUndoClear = false
    @State private var undoClearTask: Task<Void, Never>?
    @State private var previousClearedAt: Date?
    @State private var scrollToBottomToken = 0

    // Message type filters
    @State private var showID = true
    @State private var showBeacon = true
    @State private var showMail = true
    @State private var showData = true
    @State private var showPrompt = true
    @State private var showOther = true
    @State private var showSystem = true

    /// Lines filtered by clear timestamp
    private var filteredLines: [ConsoleLine] {
        guard let cutoff = clearedAt else { return lines }
        return lines.filter { $0.timestamp > cutoff }
    }

    /// Lines filtered by message type preferences
    private var typeFilteredLines: [ConsoleLine] {
        filteredLines.filter { line in
            switch line.kind {
            case .system, .error:
                return showSystem
            case .packet:
                guard let messageType = line.messageType else { return showOther }
                switch messageType {
                case .id: return showID
                case .beacon: return showBeacon
                case .mail: return showMail
                case .data: return showData
                case .prompt: return showPrompt
                case .message: return showOther
                }
            }
        }
    }

    /// Group duplicates together by content signature.
    /// Only collapse lines that are explicitly marked as duplicates (received via a different path).
    private var groupedLines: [ConsoleLineGroup] {
        ConsoleLineGrouper.group(typeFilteredLines)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: 12) {
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.checkbox)

                    Spacer()

                    // Filter toggles
                    filterToggleGroup

                    Divider()
                        .frame(height: 16)

                    Text("\(groupedLines.count) messages")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    Button("Clear") {
                        clearConsole()
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
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if showDaySeparators {
                                ForEach(dayGroupedLines) { section in
                                    DaySeparatorView(date: section.date)
                                        .padding(.vertical, 4)

                                    ForEach(section.items) { group in
                                        ConsoleLineGroupView(group: group)
                                            .id(group.id)
                                    }
                                }
                            } else {
                                ForEach(groupedLines) { group in
                                    ConsoleLineGroupView(group: group)
                                        .id(group.id)
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
                    .onChange(of: groupedLines.count) { _, _ in
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
                undoClearBanner
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Jump to Bottom Button
            if !isUserNearBottom {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            isUserNearBottom = true // Optimistic update
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
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showUndoClear)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isUserNearBottom)
    }

    // MARK: - Filter Toggles

    @ViewBuilder
    private var filterToggleGroup: some View {
        HStack(spacing: 4) {
            FilterToggle(
                label: "ID",
                isOn: $showID,
                color: .blue,
                tooltip: "Station identification broadcasts. Stations periodically announce their callsign and capabilities."
            )
            FilterToggle(
                label: "BCN",
                isOn: $showBeacon,
                color: .green,
                tooltip: "Beacon messages. Periodic broadcasts containing station info, location, or status updates."
            )
            FilterToggle(
                label: "MAIL",
                isOn: $showMail,
                color: .orange,
                tooltip: "Mail notifications. Alerts about new messages waiting at a BBS or mailbox."
            )
            FilterToggle(
                label: "DATA",
                isOn: $showData,
                color: .purple,
                tooltip: "Content messages. The actual data being exchanged — personal messages, bulletins, and transferred information."
            )
            FilterToggle(
                label: "CMD",
                isOn: $showPrompt,
                color: .cyan,
                tooltip: "Commands and prompts. Session control messages like connect/disconnect, BBS menus, and user commands."
            )
            FilterToggle(
                label: "OTHER",
                isOn: $showOther,
                color: .brown,
                tooltip: "Unclassified messages. Packets that don't fit other categories."
            )
            FilterToggle(
                label: "SYS",
                isOn: $showSystem,
                color: .gray,
                tooltip: "System messages. Connection status, errors, and internal application notifications."
            )
        }
    }

    private var dayGroupedLines: [DayGroupedSection<ConsoleLineGroup>] {
        DayGrouping.group(items: groupedLines, date: { $0.primary.timestamp })
    }

    // MARK: - Clear Actions

    private func clearConsole() {
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

            Text("Console cleared")
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

// MARK: - Console Line Grouping

nonisolated enum ConsoleLineGrouper {
    static func group(_ lines: [ConsoleLine]) -> [ConsoleLineGroup] {
        var groups: [ConsoleLineGroup] = []
        var signatureToIndex: [String: Int] = [:]

        for line in lines {
            if line.isDuplicate,
               let signature = line.contentSignature,
               let existingIndex = signatureToIndex[signature] {
                groups[existingIndex].duplicates.append(line)
                continue
            }

            let group = ConsoleLineGroup(primary: line)
            if let signature = line.contentSignature {
                signatureToIndex[signature] = groups.count
            }
            groups.append(group)
        }

        return groups
    }
}

// MARK: - Console Line Group

/// Groups a primary console line with its duplicates (received via different paths)
nonisolated struct ConsoleLineGroup: Identifiable {
    let id: UUID
    let primary: ConsoleLine
    var duplicates: [ConsoleLine]

    init(primary: ConsoleLine) {
        self.id = primary.id
        self.primary = primary
        self.duplicates = []
    }

    /// All via paths (primary + duplicates)
    var allViaPaths: [[String]] {
        var paths: [[String]] = []
        if !primary.via.isEmpty {
            paths.append(primary.via)
        }
        for dup in duplicates {
            if !dup.via.isEmpty {
                paths.append(dup.via)
            }
        }
        return paths
    }

    var duplicateCount: Int {
        duplicates.count
    }
}

/// View for a grouped console line (primary + collapsed duplicates)
struct ConsoleLineGroupView: View {
    let group: ConsoleLineGroup
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleLineView(
                line: group.primary,
                duplicateCount: group.duplicateCount,
                allViaPaths: group.allViaPaths
            )

            // Expanded duplicates (if any and expanded)
            if isExpanded && group.duplicateCount > 0 {
                // Show primary's path first if it has one
                if !group.primary.via.isEmpty {
                    HStack(spacing: 4) {
                        Text("├")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 11, design: .monospaced))
                        Text("via")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 11, design: .monospaced))
                        Text(group.primary.viaDisplay)
                            .foregroundStyle(.purple)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        Text("at \(group.primary.timestampString)")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .padding(.leading, 20)
                    .padding(.vertical, 1)
                }

                // Show each duplicate's path
                ForEach(Array(group.duplicates.enumerated()), id: \.element.id) { index, dup in
                    let isLast = index == group.duplicates.count - 1 && group.primary.via.isEmpty
                    HStack(spacing: 4) {
                        Text(isLast ? "└" : "├")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 11, design: .monospaced))

                        if !dup.via.isEmpty {
                            Text("via")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: 11, design: .monospaced))
                            Text(dup.viaDisplay)
                                .foregroundStyle(.purple)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        } else {
                            Text("(no digi path recorded)")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: 11, design: .monospaced))
                        }

                        Text("at \(dup.timestampString)")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .padding(.leading, 20)
                    .padding(.vertical, 1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if group.duplicateCount > 0 {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
        }
    }
}

struct ConsoleLineView: View {
    let line: ConsoleLine
    var duplicateCount: Int = 0
    var allViaPaths: [[String]] = []

    private let callsignSaturation: Double = 0.35
    private let callsignBrightness: Double = 0.75

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Category indicator (left border) - matches filter button colors
            RoundedRectangle(cornerRadius: 1)
                .fill(categoryBorderColor)
                .frame(width: 3)
                .help(categoryTooltip)

            // Timestamp
            Text(line.timestampString)
                .foregroundStyle(.tertiary)
                .font(.system(size: 11, design: .monospaced))

            // Callsigns
            if let from = line.from {
                Text(from)
                    .fontWeight(.medium)
                    .foregroundStyle(callsignColor(for: from))

                if let to = line.to {
                    Text("→")
                        .foregroundStyle(.tertiary)

                    Text(to)
                        .fontWeight(.medium)
                        .foregroundStyle(callsignColor(for: to))
                }
            }

            // Via path indicator (icon with tooltip)
            if !allViaPaths.isEmpty {
                DigiPathIndicator(paths: allViaPaths)
            } else if !line.via.isEmpty {
                DigiPathIndicator(paths: [line.via])
            }

            // Duplicate count badge
            if duplicateCount > 0 {
                DuplicateCountBadge(count: duplicateCount)
            }

            // Message text (wraps to container width; no chopping)
            Text(line.text)
                .foregroundStyle(messageColor)
                .textSelection(.enabled)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(rowBackground)
        .cornerRadius(4)
    }

    /// Left border color based on message category (matches filter buttons)
    private var categoryBorderColor: Color {
        switch line.kind {
        case .error:
            return .red
        case .system:
            return .gray  // Matches SYS filter button
        case .packet:
            guard let messageType = line.messageType else { return .brown }
            switch messageType {
            case .id: return .blue         // Matches ID filter button
            case .beacon: return .green    // Matches BCN filter button
            case .mail: return .orange     // Matches MAIL filter button
            case .data: return .purple     // Actual content/data (the interesting stuff!)
            case .prompt: return .cyan     // Commands, prompts, session messages
            case .message: return .brown   // Unclassified/other
            }
        }
    }

    /// Tooltip describing the message category
    private var categoryTooltip: String {
        switch line.kind {
        case .error:
            return "Error: An error or warning message"
        case .system:
            return "System: Connection status or application notification"
        case .packet:
            guard let messageType = line.messageType else {
                return "Other: Unclassified packet"
            }
            switch messageType {
            case .id:
                return "ID: Station identification broadcast"
            case .beacon:
                return "Beacon: Periodic status broadcast"
            case .mail:
                return "Mail: Message notification"
            case .data:
                return "Data: Content being transferred"
            case .prompt:
                return "Command: Session control or prompt"
            case .message:
                return "Other: Unclassified packet"
            }
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .system:
            return Color.gray.opacity(0.05)
        case .error:
            return Color.red.opacity(0.08)
        case .packet:
            return .clear
        }
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

// MARK: - Supporting Views

/// Small icon indicating digipeater path, with tooltip showing full path
struct DigiPathIndicator: View {
    let paths: [[String]]

    private var tooltipText: String {
        if paths.count == 1 {
            return "via " + paths[0].joined(separator: " → ")
        } else {
            return paths.enumerated().map { index, path in
                "Path \(index + 1): " + path.joined(separator: " → ")
            }.joined(separator: "\n")
        }
    }

    var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 10))
            .foregroundStyle(.purple.opacity(0.7))
            .help(tooltipText)
    }
}

/// Badge showing number of duplicate receptions
struct DuplicateCountBadge: View {
    let count: Int

    var body: some View {
        Text("+\(count)")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.purple)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Color.purple.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help("Received \(count + 1) times via different paths (click to expand)")
    }
}

/// Toggle button for filtering message types
struct FilterToggle: View {
    let label: String
    @Binding var isOn: Bool
    let color: Color
    var tooltip: String = ""

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(isOn ? color.opacity(0.2) : Color.gray.opacity(0.1))
            .foregroundStyle(isOn ? color : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture {
                isOn.toggle()
            }
            .help(tooltip)
    }
}

nonisolated private struct ConsoleScrollBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
