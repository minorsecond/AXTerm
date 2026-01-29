//
//  AnalyticsDashboardView.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-21.
//

import SwiftUI

struct AnalyticsDashboardView: View {
    @ObservedObject var packetEngine: PacketEngine
    @StateObject private var viewModel: AnalyticsDashboardViewModel

    @MainActor init(packetEngine: PacketEngine, viewModel: AnalyticsDashboardViewModel = AnalyticsDashboardViewModel()) {
        self.packetEngine = packetEngine
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                filterSection
                summarySection
                chartsSection
                graphSection
            }
            .padding()
        }
        .onAppear {
            viewModel.trackDashboardOpened()
            viewModel.updatePackets(packetEngine.packets)
        }
        .onReceive(packetEngine.$packets) { packets in
            viewModel.updatePackets(packets)
        }
    }

    private var filterSection: some View {
        GroupBox("Filters") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Bucket", selection: $viewModel.bucket) {
                    ForEach(TimeBucket.allCases, id: \.self) { bucket in
                        Text(bucket.displayName).tag(bucket)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Include via digipeaters", isOn: $viewModel.includeViaDigipeaters)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Minimum edge count: \(viewModel.minEdgeCount)")
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.minEdgeCount) },
                            set: { viewModel.minEdgeCount = Int($0) }
                        ),
                        in: 1...10,
                        step: 1
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var summarySection: some View {
        GroupBox("Summary") {
            if let summary = viewModel.summary {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        SummaryCard(title: "Packets", value: "\(summary.packetCount)")
                        SummaryCard(title: "Unique stations", value: "\(summary.uniqueStationsCount)")
                        SummaryCard(title: "Payload bytes", value: "\(summary.totalPayloadBytes)")
                    }

                    HStack(spacing: 16) {
                        SummaryCard(title: "Info text ratio", value: String(format: "%.0f%%", summary.infoTextRatio * 100))
                        SummaryCard(title: "UI frames", value: "\(summary.frameTypeCounts[.ui, default: 0])")
                        SummaryCard(title: "I frames", value: "\(summary.frameTypeCounts[.i, default: 0])")
                    }

                    HStack(alignment: .top, spacing: 24) {
                        StationList(title: "Top talkers", stations: summary.topTalkersByFrom)
                        StationList(title: "Top destinations", stations: summary.topDestinationsByTo)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text("No packets yet")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    private var chartsSection: some View {
        GroupBox("Charts") {
            VStack(alignment: .leading, spacing: 12) {
                AnalyticsSeriesPreview(title: "Packets", points: viewModel.series.packetsPerBucket)
                AnalyticsSeriesPreview(title: "Bytes", points: viewModel.series.bytesPerBucket)
                AnalyticsSeriesPreview(title: "Unique stations", points: viewModel.series.uniqueStationsPerBucket)
            }
            .padding(.vertical, 4)
        }
    }

    private var graphSection: some View {
        GroupBox("Network graph") {
            VStack(alignment: .leading, spacing: 8) {
                AnalyticsGraphView(viewModel: viewModel)
                    .frame(minHeight: 260)

                HStack {
                    Text("Selected: \(viewModel.selectedNodeID ?? "None")")
                    Spacer()
                    Text("Pinned: \(viewModel.pinnedNodeID ?? "None")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("Tip: click to select, double-click to pin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct StationList: View {
    let title: String
    let stations: [StationCount]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if stations.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(stations.enumerated()), id: \.offset) { _, station in
                    HStack {
                        Text(station.station)
                        Spacer()
                        Text("\(station.count)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnalyticsSeriesPreview: View {
    let title: String
    let points: [AnalyticsSeriesPoint]

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            if points.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(Array(points.prefix(8).enumerated()), id: \.offset) { _, point in
                    HStack {
                        Text(Self.formatter.string(from: point.bucket))
                            .frame(width: 60, alignment: .leading)
                        Spacer()
                        Text("\(point.value)")
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AnalyticsGraphView: View {
    @ObservedObject var viewModel: AnalyticsDashboardViewModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, _ in
                    let positions = Dictionary(uniqueKeysWithValues: viewModel.nodePositions.map {
                        ($0.id, CGPoint(x: $0.x, y: $0.y))
                    })
                    for edge in viewModel.edges {
                        guard let source = positions[edge.source], let target = positions[edge.target] else { continue }
                        var path = Path()
                        path.move(to: source)
                        path.addLine(to: target)
                        context.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                    }
                }

                ForEach(viewModel.nodePositions, id: \.id) { node in
                    let isSelected = viewModel.selectedNodeID == node.id
                    let isPinned = viewModel.pinnedNodeID == node.id
                    let isHovered = viewModel.hoveredNodeID == node.id

                    Circle()
                        .fill(nodeColor(selected: isSelected, pinned: isPinned, hovered: isHovered))
                        .frame(width: isPinned ? 16 : 12, height: isPinned ? 16 : 12)
                        .overlay(
                            Circle()
                                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                        )
                        .position(x: node.x, y: node.y)
                        .onTapGesture {
                            viewModel.selectNode(node.id)
                        }
                        .onTapGesture(count: 2) {
                            viewModel.togglePinnedNode(node.id)
                        }
                        .onHover { hovering in
                            viewModel.updateHover(for: node.id, isHovering: hovering)
                        }
                }
            }
            .onAppear {
                viewModel.updateLayout(size: proxy.size)
            }
            .onChange(of: proxy.size) { _, newSize in
                viewModel.updateLayout(size: newSize)
            }
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func nodeColor(selected: Bool, pinned: Bool, hovered: Bool) -> Color {
        if pinned {
            return .orange
        }
        if selected {
            return .accentColor
        }
        if hovered {
            return .blue
        }
        return .primary
    }
}
