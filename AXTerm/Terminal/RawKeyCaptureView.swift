//
//  RawKeyCaptureView.swift
//  AXTerm
//
//  The raw field: takes keys as keys, not as edits to a text field. See
//  Docs/TerminalInputModes.md for which key sends which byte.
//

import SwiftUI

/// What the raw field shows and where its keys go.
struct RawTerminalField: View {
    /// The far end's line so far: a prompt with no CR yet.
    let prompt: String
    /// The keys typed on this line, when Local Echo is on.
    let echo: String
    let isEnabled: Bool
    let onKey: (RawKeyCoalescer.Key) -> Void

    @State private var isFocused = false

    #if os(macOS)
    static let fieldHeight: CGFloat = 22
    #else
    static let fieldHeight: CGFloat = 34
    #endif

    var body: some View {
        ZStack(alignment: .leading) {
            RawKeyCaptureRepresentable(
                isEnabled: isEnabled,
                onKey: onKey,
                onFocusChange: { isFocused = $0 })

            HStack(spacing: 0) {
                if prompt.isEmpty && echo.isEmpty && !isFocused {
                    Text(isEnabled ? "Raw: click here, then type. Keys go to the station as you press them."
                                   : "Raw: connect to type.")
                        .foregroundStyle(.tertiary)
                } else {
                    (Text(prompt).foregroundColor(.secondary) + Text(echo))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if isFocused && isEnabled {
                        Text("\u{258F}")   // a thin caret where the next key lands
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 6)
            .allowsHitTesting(false)
        }
        // The key view has no height of its own, so without a fixed one
        // SwiftUI let it take every point the compose area offered (smoke
        // run 10.1: half the window). The height a rounded-border text
        // field has on each platform.
        .frame(height: Self.fieldHeight)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(platform: .platformTextBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor : Color.secondary.opacity(0.35),
                              lineWidth: isFocused ? 2 : 1)
        )
        .opacity(isEnabled ? 1 : 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Raw terminal input")
        .accessibilityValue(prompt + echo)
        .accessibilityHint("Each key is sent to the station as it is pressed.")
        .accessibilityIdentifier("terminalRawField")
        .help("Raw mode: keys go to the station as you type. Return sends CR, Delete sends BS, "
              + "Ctrl and a letter sends that control code. Typing is sent after 1 s of quiet, "
              + "at once for Return or a control key, or when a frame fills.")
    }
}

#if os(macOS)
import AppKit

private struct RawKeyCaptureRepresentable: NSViewRepresentable {
    let isEnabled: Bool
    let onKey: (RawKeyCoalescer.Key) -> Void
    let onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> RawKeyCaptureNSView {
        let view = RawKeyCaptureNSView()
        view.onKey = onKey
        view.onFocusChange = onFocusChange
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: RawKeyCaptureNSView, context: Context) {
        view.onKey = onKey
        view.onFocusChange = onFocusChange
        view.isEnabled = isEnabled
    }
}

/// Takes key presses while it is first responder and turns them into raw
/// keys. Command shortcuts still reach the menus; Paste is handled here.
final class RawKeyCaptureNSView: NSView {
    var onKey: ((RawKeyCoalescer.Key) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var isEnabled = true {
        didSet {
            if !isEnabled, window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
        }
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingType: NSFocusRingType {
        get { .none }   // the SwiftUI border shows focus
        set {}
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Switching to Raw is a request to type there.
        guard isEnabled, let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if isEnabled { window?.makeFirstResponder(self) }
    }

    override func becomeFirstResponder() -> Bool {
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusChange?(false)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Return, Esc and Ctrl-letter are keys here, not shortcuts for a
        // button elsewhere in the window.
        guard window?.firstResponder === self, isEnabled else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return super.performKeyEquivalent(with: event) }
        if flags.contains(.control) || event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if flags.contains(.control) {
            // Ctrl and a key that has no control code (an arrow, a digit)
            // sends nothing.
            if let character = event.charactersIgnoringModifiers?.first,
               let byte = RawKeyCoalescer.controlByte(for: character) {
                onKey?(.control(byte))
            }
            return
        }
        switch event.keyCode {
        case 36, 76: onKey?(.returnKey)     // Return, keypad Enter
        case 51: onKey?(.backspace)         // Delete
        case 48: onKey?(.tab)
        case 53: onKey?(.escape)
        default:
            // Arrows, function keys and forward delete have no byte to send.
            if let scalar = event.characters?.unicodeScalars.first,
               (0xF700...0xF8FF).contains(scalar.value) || scalar.value == 0x7F {
                return
            }
            // Text goes through the input system so option and dead-key
            // characters arrive composed.
            interpretKeyEvents([event])
        }
    }

    override func insertText(_ insertString: Any) {
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        onKey?(.text(text))
    }

    override func doCommand(by selector: Selector) {
        // Every key that reaches here was mapped in keyDown; anything else
        // is an editing command with no byte, ignored without a beep.
    }

    @objc func paste(_ sender: Any?) {
        guard isEnabled, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        onKey?(.text(text))
    }
}

extension RawKeyCaptureNSView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)) {
            return isEnabled && NSPasteboard.general.string(forType: .string) != nil
        }
        return false
    }
}

#else
import UIKit

private struct RawKeyCaptureRepresentable: UIViewRepresentable {
    let isEnabled: Bool
    let onKey: (RawKeyCoalescer.Key) -> Void
    let onFocusChange: (Bool) -> Void

    func makeUIView(context: Context) -> RawKeyCaptureUIView {
        let view = RawKeyCaptureUIView()
        view.onKey = onKey
        view.onFocusChange = onFocusChange
        view.isEnabled = isEnabled
        return view
    }

    func updateUIView(_ view: RawKeyCaptureUIView, context: Context) {
        view.onKey = onKey
        view.onFocusChange = onFocusChange
        view.isEnabled = isEnabled
    }
}

/// The iOS raw field: the on-screen keyboard through `UIKeyInput`, and a
/// hardware keyboard's Ctrl and Esc through key commands.
final class RawKeyCaptureUIView: UIView, UIKeyInput {
    var onKey: ((RawKeyCoalescer.Key) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var isEnabled = true {
        didSet { if !isEnabled, isFirstResponder { resignFirstResponder() } }
    }

    // UITextInputTraits: what is typed goes out exactly as typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func tapped() {
        if isEnabled { becomeFirstResponder() }
    }

    override var canBecomeFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    // There is always something to delete: BS goes to the station.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard isEnabled else { return }
        switch text {
        case "\n", "\r": onKey?(.returnKey)
        case "\t": onKey?(.tab)
        default: onKey?(.text(text))
        }
    }

    func deleteBackward() {
        guard isEnabled else { return }
        onKey?(.backspace)
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = "abcdefghijklmnopqrstuvwxyz[]\\".map { letter in
            let command = UIKeyCommand(input: String(letter), modifierFlags: .control,
                                       action: #selector(controlKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                                  action: #selector(escapeKey(_:)))
        escape.wantsPriorityOverSystemBehavior = true
        commands.append(escape)
        return commands
    }

    @objc private func controlKey(_ command: UIKeyCommand) {
        guard let character = command.input?.first,
              let byte = RawKeyCoalescer.controlByte(for: character) else { return }
        onKey?(.control(byte))
    }

    @objc private func escapeKey(_ command: UIKeyCommand) {
        onKey?(.escape)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return isEnabled && UIPasteboard.general.hasStrings }
        return false
    }

    override func paste(_ sender: Any?) {
        guard isEnabled, let text = UIPasteboard.general.string, !text.isEmpty else { return }
        onKey?(.text(text))
    }
}
#endif
