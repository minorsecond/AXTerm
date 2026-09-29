import SwiftUI

/// A one-field "type a value and confirm" prompt.
///
/// Replaces the `NSAlert`-with-an-accessory-`NSTextField` pattern that these
/// settings panes used. That pattern was macOS-only, but more importantly it
/// ran `runModal()`, which blocks the main run loop until the operator
/// answers — freezing the packet stream, the session timers and the UI behind
/// a dialog asking for a callsign. A SwiftUI alert does not.
///
/// Every prompt states *why* the value is wanted, not just what to type,
/// because several of these change what the station will do without asking
/// again — auto-accepting files from a callsign, for instance.
nonisolated struct TextEntryPrompt: Identifiable {
    let id: String
    let title: String
    let message: String
    var placeholder: String = ""
    var confirmTitle: String = "Add"
    /// True for callsigns: they travel upper-case on the air, and every
    /// comparison in the app spells them that way.
    var uppercases: Bool = false
    /// Called with the trimmed value. Not called for an empty entry or a
    /// cancel.
    let onCommit: (String) -> Void
}

extension View {
    /// Presents `prompt` when it is non-nil, clearing it when dismissed.
    func textEntryPrompt(_ prompt: Binding<TextEntryPrompt?>) -> some View {
        modifier(TextEntryPromptModifier(prompt: prompt))
    }
}

private struct TextEntryPromptModifier: ViewModifier {
    @Binding var prompt: TextEntryPrompt?
    @State private var text = ""

    func body(content: Content) -> some View {
        content.alert(prompt?.title ?? "", isPresented: Binding(
            get: { prompt != nil },
            set: { if !$0 { dismiss() } })) {
            TextField(prompt?.placeholder ?? "", text: $text)
                #if os(iOS)
                .textInputAutocapitalization(prompt?.uppercases == true ? .characters : .sentences)
                .autocorrectionDisabled(prompt?.uppercases == true)
                #endif

            Button(prompt?.confirmTitle ?? "OK") { commit() }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text(prompt?.message ?? "")
        }
    }

    private func commit() {
        guard let prompt else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            prompt.onCommit(prompt.uppercases ? trimmed.uppercased() : trimmed)
        }
        dismiss()
    }

    private func dismiss() {
        prompt = nil
        text = ""
    }
}
