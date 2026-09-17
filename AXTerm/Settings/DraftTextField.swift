import SwiftUI

/// A text field that edits a local copy and writes back to the bound value
/// when typing pauses, when it loses focus, and on Return — but not on
/// every keystroke.
///
/// Radio fields bind through to `AppSettingsStore`, whose every mutation
/// re-encodes the whole radio list to JSON and re-renders the settings
/// window. Doing that per keystroke is what makes typing lag. Holding a
/// local draft and committing once a burst is over keeps typing cheap.
///
/// It waited for focus loss alone until 2026-09-17. On macOS a button does
/// not take focus from a text field, so clicking one left the field still
/// focused, the draft uncommitted, and the button acting on the previous
/// value — a radio's Wi-Fi address typed in full, and "Enter the radio's
/// address first." next to it, with an empty `lanHost` on disk.
struct DraftTextField: View {
    let titleKey: String
    @Binding var text: String
    var prompt: String?
    var onCommit: (() -> Void)?

    @State private var draft = ""
    @FocusState private var focused: Bool

    /// How long typing has to pause before the draft is written back.
    ///
    /// Long enough that a burst of keystrokes is still one write, short
    /// enough to have landed by the time a hand reaches a button.
    private static let quietPeriod = Duration.milliseconds(400)

    init(_ titleKey: String,
         text: Binding<String>,
         prompt: String? = nil,
         onCommit: (() -> Void)? = nil) {
        self.titleKey = titleKey
        self._text = text
        self.prompt = prompt
        self.onCommit = onCommit
    }

    var body: some View {
        TextField(titleKey, text: $draft, prompt: prompt.map(Text.init))
            .focused($focused)
            .onAppear { draft = text }
            // Keep the draft in step with outside changes only while the
            // operator is not the one typing, so a load or reset shows.
            .onChange(of: text) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit { commit() }
            // Restarted by every keystroke, so it only fires once the
            // operator stops typing. This is what makes the value land
            // without anything having to take the focus away.
            .task(id: draft) {
                guard draft != text else { return }
                try? await Task.sleep(for: Self.quietPeriod)
                guard !Task.isCancelled else { return }
                commit()
            }
    }

    private func commit() {
        if draft != text { text = draft }
        onCommit?()
    }
}
