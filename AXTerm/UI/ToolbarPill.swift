import SwiftUI

/// The shape of a status item in the window toolbar.
///
/// From macOS 26 the toolbar puts every item on its own glass capsule. An
/// item that also draws a capsule shows as a pill inside a pill, and one
/// that brings no padding sits with its text against the glass edge. So on
/// macOS 26 this adds padding only, and on earlier systems, where toolbar
/// items have no background, it draws the capsule itself.
struct ToolbarPill: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            content
                .padding(.horizontal, 8)
                .contentShape(Capsule())
        } else {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color(platform: .platformSeparator).opacity(0.35), lineWidth: 0.5)
                )
                .contentShape(Capsule())
        }
        #else
        content
        #endif
    }
}

extension View {
    func toolbarPill() -> some View {
        modifier(ToolbarPill())
    }
}
