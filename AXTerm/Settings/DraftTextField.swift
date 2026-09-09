import SwiftUI

/// A text field that edits a local copy and writes back to the bound value
/// only when editing ends — on focus loss or Return, not on every keystroke.
///
/// Radio fields bind through to `AppSettingsStore`, whose every mutation
/// re-encodes the whole radio list to JSON and re-renders the settings
/// window. Doing that per keystroke is what makes typing lag. Holding a
/// local draft and committing once keeps typing cheap while still saving
/// the moment the field loses focus.
struct DraftTextField: View {
    let titleKey: String
    @Binding var text: String
    var prompt: String?
    var onCommit: (() -> Void)?

    @State private var draft = ""
    @FocusState private var focused: Bool

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
    }

    private func commit() {
        if draft != text { text = draft }
        onCommit?()
    }
}
