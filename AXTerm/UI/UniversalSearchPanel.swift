//
//  UniversalSearchPanel.swift
//  AXTerm
//
//  The floating results panel under the toolbar search field — every
//  category the query matched, grouped, capped, with honest totals.
//  Rendering only: UniversalSearchIndex decides what appears.
//

import SwiftUI

struct UniversalSearchPanel: View {
    let results: UniversalSearchResults
    let query: String
    var onOpen: (UniversalSearchResults.Destination) -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if results.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(results.sections) { section in
                            sectionView(section)
                        }
                    }
                }
                .frame(maxHeight: 460)
            }
        }
        .frame(width: 470)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
    }

    private var header: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Everything matching \u{201C}\(query)\u{201D}")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close. The text stays and keeps filtering the current page.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No matches anywhere")
                .font(.callout.weight(.medium))
            Text("Stations, the node directory, routes, mail, packets and "
                 + "terminal output were all checked.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }

    private func sectionView(_ section: UniversalSearchResults.Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: section.category.icon)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text(section.category.rawValue)
                    .font(.caption.weight(.semibold))
                Spacer()
                // The honest total, and the way to the rest of it.
                if let destination = section.rows.first?.destination {
                    Button {
                        onOpen(categoryDestination(section, fallback: destination))
                    } label: {
                        HStack(spacing: 3) {
                            Text(section.totalCount == 1
                                 ? "1 match"
                                 : "\(section.totalCount) matches")
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open the page this category lives on, with the "
                          + "search applied.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ForEach(section.rows) { row in
                SearchResultRow(row: row, monospaced: usesMonospace(section.category)) {
                    onOpen(row.destination)
                }
            }
        }
    }

    /// The header chevron opens the category's page rather than one row's
    /// destination — for profile rows that means the directory page,
    /// where the same search shows every match.
    private func categoryDestination(
        _ section: UniversalSearchResults.Section,
        fallback: UniversalSearchResults.Destination
    ) -> UniversalSearchResults.Destination {
        switch section.category {
        case .stations: return .terminal
        case .directory: return .nodes(query: query)
        case .routes: return .routes
        case .mail: return .mail
        case .packets: return .packets
        case .terminal: return .terminal
        }
    }

    private func usesMonospace(_ category: UniversalSearchResults.Category) -> Bool {
        switch category {
        case .stations, .directory, .routes, .packets: return true
        case .mail, .terminal: return false
        }
    }
}

/// One clickable result with a hover highlight.
private struct SearchResultRow: View {
    let row: UniversalSearchResults.Row
    let monospaced: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(monospaced
                          ? .system(.callout, design: .monospaced).weight(.medium)
                          : .callout.weight(.medium))
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.accentColor.opacity(0.14) : Color.clear)
        .onHover { hovering = $0 }
    }
}
