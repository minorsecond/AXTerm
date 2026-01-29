//
//  StationInspectorView.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-23.
//

import SwiftUI

struct StationInspectorView: View {
    @ObservedObject var viewModel: StationInspectorViewModel
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statsSection
            peersSection
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 520, minHeight: 360, idealHeight: 420)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") {
                    dismiss()
                    onClose?()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.stats.stationID)
                .font(.title3.weight(.semibold))
            Text("Inspect Station")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statsSection: some View {
        GroupBox("Packet counts") {
            HStack(spacing: 16) {
                metricCell(title: "From", value: viewModel.stats.fromCount)
                metricCell(title: "To", value: viewModel.stats.toCount)
                metricCell(title: "Via", value: viewModel.stats.viaCount)
            }
            .padding(.vertical, 4)
        }
    }

    private var peersSection: some View {
        GroupBox("Top peers") {
            if viewModel.stats.topPeers.isEmpty {
                Text("No peer traffic")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.stats.topPeers) { peer in
                        HStack {
                            Text(peer.stationID)
                            Spacer()
                            Text("\(peer.count)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func metricCell(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
