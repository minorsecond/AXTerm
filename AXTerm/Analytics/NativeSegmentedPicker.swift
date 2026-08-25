//
//  NativeSegmentedPicker.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-09.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A segmented control with a stable per-segment explanation.
///
/// On macOS this wraps `NSSegmentedControl` rather than using SwiftUI's
/// `Picker`: the segment tooltips flicker under the SwiftUI control, and the
/// tooltips are the point — CLAUDE.md §11 requires each choice to explain
/// what it selects, not merely label it.
///
/// iOS has no tooltip and no flicker to work around, so it uses the plain
/// SwiftUI picker with the same explanations reachable by tap. Same API, same
/// obligation, each platform's own control.
struct NativeSegmentedPicker<T: Hashable & CaseIterable & Identifiable>: View {
    @Binding var selection: T
    let items: [T]
    let title: (T) -> String
    let tooltip: (T) -> String
    let accessibilityLabel: String?

    init(
        selection: Binding<T>,
        items: [T],
        title: @escaping (T) -> String,
        tooltip: @escaping (T) -> String,
        accessibilityLabel: String? = nil
    ) {
        self._selection = selection
        self.items = items
        self.title = title
        self.tooltip = tooltip
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        #if os(macOS)
        AppKitSegmentedPicker(selection: $selection, items: items, title: title,
                              tooltip: tooltip, accessibilityLabel: accessibilityLabel)
        #else
        Picker(accessibilityLabel ?? "", selection: $selection) {
            ForEach(items) { item in
                Text(title(item)).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // One combined explanation rather than per-segment: a touch platform
        // has nowhere to hover, and a popover per segment would fight the
        // control's own tap handling.
        .explain(items.map { "\(title($0)): \(tooltip($0))" }.joined(separator: "\n\n"))
        #endif
    }
}

#if os(macOS)

private struct AppKitSegmentedPicker<T: Hashable & CaseIterable & Identifiable>: NSViewRepresentable {
    @Binding var selection: T
    let items: [T]
    let title: (T) -> String
    let tooltip: (T) -> String
    let accessibilityLabel: String?

    func makeNSView(context: Context) -> NSSegmentedControl {
        let labels = items.map(title)
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))

        control.segmentStyle = .automatic
        control.controlSize = .regular

        if let accessibilityLabel {
            control.setAccessibilityLabel(accessibilityLabel)
        }

        // Initial tooltips initialization
        updateSegments(control)

        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self

        // Update selection if it changed from SwiftUI side
        if let index = items.firstIndex(of: selection), nsView.selectedSegment != index {
            nsView.selectedSegment = index
        }

        // Ensure tooltips are still correct (though they shouldn't change for this use case)
        updateSegments(nsView)
    }

    private func updateSegments(_ control: NSSegmentedControl) {
        for (index, item) in items.enumerated() {
            if index < control.segmentCount {
                control.setToolTip(tooltip(item), forSegment: index)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: AppKitSegmentedPicker

        init(_ parent: AppKitSegmentedPicker) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            if index >= 0 && index < parent.items.count {
                let newItem = parent.items[index]
                if parent.selection != newItem {
                    parent.selection = newItem
                }
            }
        }
    }
}

#endif
