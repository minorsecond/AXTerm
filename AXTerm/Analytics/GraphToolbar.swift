//
//  GraphToolbar.swift
//  AXTerm
//
//  A HIG-compliant toolbar for the network graph with view controls,
//  focus indicator, and selection indicator.
//
//  Design principles:
//  - Single canonical location for view controls (Fit, Reset)
//  - Clear focus state indicator with settings popover
//  - Selection count with clear action
//  - No duplicate controls elsewhere in the UI
//

import SwiftUI

// MARK: - Graph Toolbar

/// Toolbar positioned above the network graph with view controls,
/// focus indicator, and selection indicator.
struct GraphToolbar: View {
    @Binding var focusState: GraphFocusState
    let selectedNodeCount: Int
    let onFitToView: () -> Void
    let onResetView: () -> Void
    let onClearSelection: () -> Void
    let onClearFocus: () -> Void
    let onChangeAnchor: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Left group: View controls
            viewControlsGroup

            // Center: Focus indicator (when active)
            if focusState.isFocusEnabled, focusState.anchorNodeID != nil {
                Divider()
                    .frame(height: 16)
                focusIndicator
            }

            Spacer()

            // Right: Selection indicator (when nodes selected)
            if selectedNodeCount > 0 {
                selectionIndicator
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - View Controls

    private var viewControlsGroup: some View {
        HStack(spacing: 4) {
            Button(action: onFitToView) {
                Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Adjust zoom to fit all visible nodes")

            Button(action: onResetView) {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Reset pan and zoom to default. Does not affect selection or focus.")
        }
        .font(.system(size: 12))
    }

    // MARK: - Focus Indicator

    @State private var showingFocusSettings = false

    private var focusIndicator: some View {
        HStack(spacing: 6) {
            // Focus pill button (opens settings)
            Button(action: { showingFocusSettings.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                        .font(.system(size: 10, weight: .medium))
                    Text(focusPillLabel)
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(focusPillTooltip)
            .popover(isPresented: $showingFocusSettings, arrowEdge: .bottom) {
                FocusSettingsPopover(
                    focusState: $focusState,
                    onChangeAnchor: onChangeAnchor
                )
            }

            // Clear focus button
            Button(action: onClearFocus) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Exit focus mode and show all nodes")
        }
    }

    private var focusPillLabel: String {
        let name = focusState.anchorDisplayName ?? focusState.anchorNodeID ?? "Unknown"
        return "\(name) (\(focusState.maxHops))"
    }

    private var focusPillTooltip: String {
        let name = focusState.anchorDisplayName ?? focusState.anchorNodeID ?? "Unknown"
        return "Graph filtered to \(focusState.maxHops) hops from \(name). Click to change settings."
    }

    // MARK: - Selection Indicator

    private var selectionIndicator: some View {
        HStack(spacing: 6) {
            Text(selectionLabel)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)

            Button(action: onClearSelection) {
                Text("Clear")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Deselect all nodes")
        }
    }

    private var selectionLabel: String {
        if selectedNodeCount == 1 {
            return "1 node selected"
        } else {
            return "\(selectedNodeCount) nodes selected"
        }
    }
}

// MARK: - Focus Settings Popover

/// Popover for adjusting focus settings (hop count, anchor)
private struct FocusSettingsPopover: View {
    @Binding var focusState: GraphFocusState
    let onChangeAnchor: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Anchor info
            VStack(alignment: .leading, spacing: 4) {
                Text("Focus Anchor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(focusState.anchorDisplayName ?? focusState.anchorNodeID ?? "Unknown")
                    .font(.system(size: 13, weight: .semibold))
            }

            Divider()

            // Hop count stepper
            HStack {
                Text("Hops:")
                    .font(.system(size: 12))
                Spacer()
                Stepper(
                    value: $focusState.maxHops,
                    in: GraphFocusState.hopRange
                ) {
                    Text("\(focusState.maxHops)")
                        .font(.system(size: 12).monospacedDigit())
                        .frame(width: 20, alignment: .trailing)
                }
                .controlSize(.small)
            }
            .help("Number of connection hops to include from the anchor node")

            Divider()

            // Change anchor button
            Button(action: onChangeAnchor) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Use Selected as Anchor")
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Set the currently selected node as the focus anchor")
        }
        .padding(12)
        .frame(width: 200)
    }
}

// MARK: - Preview

#if DEBUG
struct GraphToolbar_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // No focus, no selection
            GraphToolbar(
                focusState: .constant(GraphFocusState()),
                selectedNodeCount: 0,
                onFitToView: {},
                onResetView: {},
                onClearSelection: {},
                onClearFocus: {},
                onChangeAnchor: {}
            )

            // With focus active
            GraphToolbar(
                focusState: .constant(GraphFocusState(
                    isFocusEnabled: true,
                    anchorNodeID: "K0EPI-7",
                    anchorDisplayName: "K0EPI-7",
                    maxHops: 2
                )),
                selectedNodeCount: 0,
                onFitToView: {},
                onResetView: {},
                onClearSelection: {},
                onClearFocus: {},
                onChangeAnchor: {}
            )

            // With selection
            GraphToolbar(
                focusState: .constant(GraphFocusState()),
                selectedNodeCount: 3,
                onFitToView: {},
                onResetView: {},
                onClearSelection: {},
                onClearFocus: {},
                onChangeAnchor: {}
            )

            // With both focus and selection
            GraphToolbar(
                focusState: .constant(GraphFocusState(
                    isFocusEnabled: true,
                    anchorNodeID: "K0EPI-7",
                    anchorDisplayName: "K0EPI-7",
                    maxHops: 3
                )),
                selectedNodeCount: 1,
                onFitToView: {},
                onResetView: {},
                onClearSelection: {},
                onClearFocus: {},
                onChangeAnchor: {}
            )
        }
        .padding()
        .frame(width: 500)
    }
}
#endif
