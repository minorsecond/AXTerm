import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The case rule for text made of callsigns: one call, a call with an SSID,
/// a digipeater path, an alias list.
///
/// Only ASCII a-z changes. Callsigns are ASCII on the air, and leaving every
/// other character alone keeps the text the same length, so the caret stays
/// where the operator left it. `"ß".uppercased()` is `"SS"`, which would
/// shift it. A non-ASCII character is still an error, and the field's own
/// validation says so; changing its case would only hide what was typed.
nonisolated enum CallsignCase {
    static func uppercased(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isLowerASCII) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.map { scalar in
            isLowerASCII(scalar) ? Unicode.Scalar(scalar.value - 0x20)! : scalar
        })
        return String(scalars)
    }

    private static func isLowerASCII(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x61 && scalar.value <= 0x7A
    }
}

extension View {
    /// Makes a text field a callsign field: upper-case as the operator
    /// types, and never autocorrected.
    ///
    /// The upper-casing happens in `onChange`, after the keystroke lands.
    /// Doing it in the binding's setter does not work on iOS: a focused
    /// field does not redraw a value its own binding rewrote, so "k0epi"
    /// stayed lower-case on screen while the store held "K0EPI". The
    /// keyboard hint alone is not enough either, because a paste or a
    /// hardware keyboard ignores it.
    ///
    /// Pass the same binding the field edits. A setter that rewrites case
    /// defeats this for the reason above, so let the value through as typed
    /// and let this modifier fix it. With `isEnabled` false the field is
    /// left as an ordinary text field.
    func callsignInput(_ text: Binding<String>, isEnabled: Bool = true) -> some View {
        modifier(CaseRuleInput(text: text, isEnabled: isEnabled, rule: CallsignCase.uppercased))
    }

    /// Makes a text field a Maidenhead locator field: `Maidenhead.formatted`
    /// applied as the operator types (DM79po), by the same means and for the
    /// same reason as `callsignInput`.
    func gridSquareInput(_ text: Binding<String>) -> some View {
        modifier(CaseRuleInput(text: text, isEnabled: true, rule: Maidenhead.formatted))
    }
}

/// Rewrites a field's text by `rule` after each edit, and sets the keyboard
/// up for text that is not prose.
private struct CaseRuleInput: ViewModifier {
    @Binding var text: String
    let isEnabled: Bool
    let rule: (String) -> String

    func body(content: Content) -> some View {
        // Always the same modifiers, with values that depend on isEnabled,
        // so turning it on or off never gives the field a new identity.
        content
            .autocorrectionDisabled(isEnabled)
            #if os(iOS)
            .textInputAutocapitalization(isEnabled ? .characters : nil)
            .keyboardType(isEnabled ? .asciiCapable : .default)
            #endif
            .onChange(of: text) { _, typed in
                guard isEnabled else { return }
                let ruled = rule(typed)
                // The write lands back here with nothing left to change, so
                // it stops after one round.
                guard ruled != typed else { return }
                #if os(macOS)
                if let editor = FieldEditorRewrite.editor(showing: typed) {
                    FieldEditorRewrite.replace(in: editor, with: ruled)
                    return
                }
                #endif
                text = ruled
            }
    }
}

#if os(macOS)
/// Rewrites the text of the field being edited on the Mac, keeping the caret.
///
/// A Mac text field given a new value through its binding puts the caret at
/// the end, so a letter typed into the middle of "K0PI" would send the caret
/// away from where the operator is typing. Editing the field editor instead
/// keeps the selection, and its change notice carries the new text to the
/// binding as if it had been typed.
@MainActor
private enum FieldEditorRewrite {
    /// The field editor holding exactly `typed`, if a text field is being
    /// edited. Nil for a value set from code, which has no caret to keep.
    static func editor(showing typed: String) -> NSTextView? {
        for window in NSApp.windows {
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
               editor.string == typed {
                return editor
            }
        }
        return nil
    }

    static func replace(in editor: NSTextView, with ruled: String) {
        // An input method mid-composition owns the text; the next change,
        // once it commits, comes back through here.
        guard !editor.hasMarkedText() else { return }
        let whole = NSRange(location: 0, length: (editor.string as NSString).length)
        guard editor.shouldChangeText(in: whole, replacementString: ruled) else { return }
        let selection = editor.selectedRanges.map(\.rangeValue)
        editor.textStorage?.replaceCharacters(in: whole, with: ruled)
        // The case rules keep the length; a trimmed locator can shrink, so
        // the old selection is clamped to what is left.
        let length = (ruled as NSString).length
        editor.selectedRanges = selection.map { range in
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location,
                                          length: min(range.length, length - location)))
        }
        editor.didChangeText()
    }
}
#endif
