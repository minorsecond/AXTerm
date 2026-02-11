import AppKit
import SwiftUI

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
        let combo = NSComboBox(frame: .zero)
        combo.usesDataSource = false
        combo.completes = true
        combo.isEditable = true
        combo.delegate = context.coordinator
        combo.placeholderString = placeholder
        combo.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        combo.addItems(withObjectValues: displayItems())
        if let accessibilityIdentifier {
            combo.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        return combo
    }

    func updateNSView(_ nsView: NSComboBox, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.removeAllItems()
        nsView.addItems(withObjectValues: displayItems())
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

        init(_ parent: EditableComboBox) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            guard !parent.isHeaderItem(combo.stringValue) else {
                combo.stringValue = parent.text
                return
            }
            parent.text = combo.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit?()
                return true
            }
            return false
        }
    }
}
