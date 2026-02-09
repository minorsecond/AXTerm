//
//  NativeSegmentedPicker.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-09.
//

import SwiftUI
import AppKit

/// A native macOS segmented control wrapper for SwiftUI that supports stable per-segment tooltips.
/// This approach satisfies HIG requirements for native appearance while solving tooltip flickering
/// issues occasionally seen with standard SwiftUI Pickers on macOS.
struct NativeSegmentedPicker<T: Hashable & CaseIterable & Identifiable>: NSViewRepresentable {
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
        var parent: NativeSegmentedPicker

        init(_ parent: NativeSegmentedPicker) {
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
