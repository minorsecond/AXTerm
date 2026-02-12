import AppKit
import SwiftUI

private final class FirstClickPopupComboBox: NSComboBox {
    private var pendingOpenOnItemsAvailable = false

    override func mouseDown(with event: NSEvent) {
        let hadFocus = (window?.firstResponder === self) || (window?.firstResponder === currentEditor())
        guard !hadFocus else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        requestPopupOpen()
    }

    func flushPendingPopupOpenIfNeeded() {
        guard pendingOpenOnItemsAvailable, numberOfItems > 0 else { return }
        pendingOpenOnItemsAvailable = false
        DispatchQueue.main.async { [weak self] in
            self?.performClick(nil)
        }
    }

    private func requestPopupOpen() {
        guard numberOfItems > 0 else {
            pendingOpenOnItemsAvailable = true
            return
        }
        pendingOpenOnItemsAvailable = false
        DispatchQueue.main.async { [weak self] in
            self?.performClick(nil)
        }
    }
}

struct EditableComboBoxGroup: Hashable {
    let title: String
    let items: [String]
}

struct EditableComboBox: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let items: [String]
    var groups: [EditableComboBoxGroup] = []
    var width: CGFloat
    var focusRequested: Binding<Bool>? = nil
    var accessibilityIdentifier: String? = nil
    var onCommit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let combo = FirstClickPopupComboBox(frame: .zero)
        combo.usesDataSource = false
        combo.completes = true
        combo.isEditable = true
        combo.delegate = context.coordinator
        combo.placeholderString = placeholder
        combo.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let newItems = displayItems()
        combo.addItems(withObjectValues: newItems)
        context.coordinator.lastItems = newItems
        if let accessibilityIdentifier {
            combo.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        return combo
    }

    func updateNSView(_ nsView: NSComboBox, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // Skip text reset if a selection is being applied asynchronously
        if coordinator.pendingSelectionValue == nil, nsView.stringValue != text {
            nsView.stringValue = text
        }

        let newItems = displayItems()
        coordinator.applyItemsIfNeeded(newItems, to: nsView)
        if let combo = nsView as? FirstClickPopupComboBox {
            combo.flushPendingPopupOpenIfNeeded()
        }

        if nsView.frame.width != width {
            nsView.frame.size.width = width
        }
        if let accessibilityIdentifier {
            nsView.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        if focusRequested?.wrappedValue == true {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
                focusRequested?.wrappedValue = false
            }
        }
    }

    private func displayItems() -> [String] {
        guard !groups.isEmpty else { return items }
        var values: [String] = []
        for group in groups where !group.items.isEmpty {
            values.append(headerTitle(for: group.title))
            values.append(contentsOf: group.items)
        }
        return values.isEmpty ? items : values
    }

    private func headerTitle(for title: String) -> String {
        "— \(title) —"
    }

    fileprivate func isHeaderItem(_ value: String) -> Bool {
        value.hasPrefix("— ") && value.hasSuffix(" —")
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: EditableComboBox
        /// Tracks the last set of items to avoid unnecessary removeAll/addAll cycles.
        var lastItems: [String] = []
        /// Set while a dropdown selection is being applied asynchronously,
        /// so updateNSView does not clobber the combo text or items before
        /// the binding update completes.
        var pendingSelectionValue: String?
        /// True while the combo's popup list is visible.
        var isPopUpVisible = false
        /// Item updates staged while popup is visible or selection commit is in-flight.
        var stagedItems: [String]?

        init(_ parent: EditableComboBox) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            let idx = combo.indexOfSelectedItem
            guard idx >= 0, idx < combo.numberOfItems else { return }
            guard let selectedValue = combo.itemObjectValue(at: idx) as? String else { return }
            guard !parent.isHeaderItem(selectedValue) else {
                combo.stringValue = parent.text
                return
            }
            // Set combo text immediately so the user sees it
            combo.stringValue = selectedValue
            // Mark pending so updateNSView won't reset the text or items
            pendingSelectionValue = selectedValue
            // Defer binding update to avoid "Publishing changes from within view updates"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.text = selectedValue
                self.pendingSelectionValue = nil
                self.applyStagedItemsIfPossible(to: combo)
            }
        }

        func comboBoxWillPopUp(_ notification: Notification) {
            isPopUpVisible = true
        }

        func comboBoxWillDismiss(_ notification: Notification) {
            isPopUpVisible = false
            guard let combo = notification.object as? NSComboBox else { return }
            applyStagedItemsIfPossible(to: combo)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit?()
                return true
            }
            return false
        }

        func applyItemsIfNeeded(_ newItems: [String], to combo: NSComboBox) {
            guard newItems != lastItems else {
                stagedItems = nil
                return
            }
            guard pendingSelectionValue == nil, !isPopUpVisible else {
                stagedItems = newItems
                return
            }
            combo.removeAllItems()
            combo.addItems(withObjectValues: newItems)
            lastItems = newItems
            stagedItems = nil
        }

        private func applyStagedItemsIfPossible(to combo: NSComboBox) {
            guard pendingSelectionValue == nil, !isPopUpVisible else { return }
            guard let stagedItems else { return }
            applyItemsIfNeeded(stagedItems, to: combo)
        }
    }
}
