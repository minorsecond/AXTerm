import SwiftUI

/// Attaches the explanation of a value to the value.
///
/// CLAUDE.md §11 makes this non-negotiable: every advanced metric must
/// explain *why* it is what it is, not merely define the term. On macOS that
/// has always been `.help()` — hover and read.
///
/// `.help()` compiles on iOS and does nothing. Porting the app as-is would
/// therefore delete every derivation explanation on the platform where the
/// operator is most likely to be standing in a field making a decision from
/// a number they cannot interrogate. A silent no-op is the worst possible
/// outcome, because nothing in the build warns anybody.
///
/// So explanations go through `.explain(_:)` instead: a tooltip where there
/// is a pointer, a tap-to-reveal popover where there is not. Same text, same
/// obligation, reachable either way.
struct ExplanationModifier: ViewModifier {

    let text: String
    /// Draws a faint indicator where there is no hover, so the operator can
    /// tell an explainable value from a plain one. On macOS the pointer
    /// discovers it, and an extra glyph next to every metric would be noise.
    var showsIndicator: Bool

    @State private var isPresented = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content.help(text)
        #else
        // The tap target is the indicator, never the content. Putting a
        // tap gesture across the whole thing swallows the wrapped control's
        // own taps — a decorated Picker or Toggle simply stops working,
        // which is how "Keep screen on" became unchangeable on iOS.
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            content
            if showsIndicator {
                Button { isPresented = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                // Plain, or a List row treats the whole row as the button.
                .buttonStyle(.plain)
                .accessibilityLabel("Explain")
                .popover(isPresented: $isPresented) { explanation }
            }
        }
        // Only where there is no indicator does the content itself explain,
        // which is the documented use for a non-interactive value or row.
        .modifier(WholeAreaTap(isEnabled: !showsIndicator, isPresented: $isPresented))
        .popover(isPresented: Binding(
            get: { isPresented && !showsIndicator },
            set: { if !$0 { isPresented = false } })) { explanation }
        #endif
    }

    #if !os(macOS)
    private var explanation: some View {
        // Sized to its text rather than to nothing.
        //
        // A `ScrollView` has no intrinsic height, so a popover containing one
        // has nothing to size itself from: iOS picked something small and the
        // sentence was cut off mid-word. Every bad-looking bubble in the app
        // was this. The text now states its own width and height, and scrolls
        // only if it genuinely exceeds the cap.
        ScrollView {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 320)
        .frame(maxHeight: 420)
        .presentationCompactAdaptation(.popover)
    }
    #endif
}

#if !os(macOS)
/// Taps the whole area only where the content is not itself interactive.
private struct WholeAreaTap: ViewModifier {
    let isEnabled: Bool
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(Rectangle())
                .onTapGesture { isPresented = true }
        } else {
            content
        }
    }
}
#endif

extension View {
    /// Explains a value. See `ExplanationModifier` for why this is not
    /// simply `.help()`.
    ///
    /// - Parameter showsIndicator: whether to mark the value as explainable
    ///   on platforms with no pointer. Default true; pass false where the
    ///   control is obviously tappable already, such as a row or a button.
    func explain(_ text: String, showsIndicator: Bool = true) -> some View {
        modifier(ExplanationModifier(text: text, showsIndicator: showsIndicator))
    }
}
