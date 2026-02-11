import AppKit
import SwiftUI

struct EditableComboBox: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let items: [String]
    var width: CGFloat
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
        combo.addItems(withObjectValues: items)
        return combo
    }

    func updateNSView(_ nsView: NSComboBox, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.removeAllItems()
        nsView.addItems(withObjectValues: items)
        if nsView.frame.width != width {
            nsView.frame.size.width = width
        }
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
