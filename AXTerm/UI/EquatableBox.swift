import SwiftUI

/// Renders `content`, but compares equal on `key` alone.
///
/// Used with `.equatable()`, this hands SwiftUI a cheap way to prune an
/// expensive subtree: while `key` is unchanged the wrapped content's `body`
/// is not re-evaluated and its observation is not re-registered, however
/// often the enclosing view re-runs. The content closure is still built each
/// time the parent's body runs — that is only property stores — but the work
/// that showed up on the profiler (`AttributeGraph`, `ObservationRegistrar`,
/// the view-tree diff) is what gets skipped.
///
/// The content is a builder rather than a stored view so nothing about it
/// enters equality; only `key` does. It is the caller's job to fold into
/// `key` everything the content's appearance depends on — an omission shows
/// as a stale view, so the key is deliberately generous.
struct EquatableBox<Content: View>: View, Equatable {
    let key: String
    @ViewBuilder let content: () -> Content

    nonisolated static func == (lhs: EquatableBox, rhs: EquatableBox) -> Bool {
        lhs.key == rhs.key
    }

    var body: some View { content() }
}

extension View {
    /// For a page kept mounted behind the others: it fills what it is given
    /// and never sets the window's minimum size.
    ///
    /// Opacity hides a view without taking it out of layout, so a hidden page
    /// that grows (a banner per heard station, captions that refuse to wrap
    /// short) raises the window's minimum on every page. The main window grew
    /// past the screen that way and AppKit threw while SwiftUI resized it
    /// (smoke run 2026-10-03-1, issue 22). Anything taller than the space is
    /// clipped at the bottom instead.
    func keptAliveFrame() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
    }
}

extension View {
    /// A layer kept mounted over this view, sized to it and never sizing it.
    ///
    /// The map is kept alive behind every page. In a ZStack its minimum
    /// height was the page's, and a wrapped line of text inside it could
    /// make the window taller than the screen. An overlay takes this view's
    /// size and has no say in it.
    func keptAliveLayer<Layer: View>(@ViewBuilder _ layer: () -> Layer) -> some View {
        overlay { layer() }
    }

    /// As above, and while `active` is false the layer keeps the size it
    /// last had rather than following this view. Hiding the sidebar animates
    /// the page's width; the kept-alive map followed it and MapKit
    /// re-rendered it on every frame, about 460 ms of main-thread work per
    /// toggle on the Packets page (2026-10-10). Held still, it costs nothing
    /// until its page opens.
    func keptAliveLayer<Layer: View>(active: Bool, @ViewBuilder _ layer: () -> Layer) -> some View {
        modifier(KeptAliveLayer(active: active, layer: layer()))
    }
}

private struct KeptAliveLayer<Layer: View>: ViewModifier {
    let active: Bool
    let layer: Layer
    @State private var held: CGSize?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                // Follow while showing, and take a first size to hold.
                if active || held == nil { held = size }
            }
            .onChange(of: active) { _, isActive in
                if isActive { held = nil }
            }
            .overlay(alignment: .topLeading) {
                // One view either way, so the layer is never rebuilt: an
                // unset frame follows the page, a set one holds.
                let hold = active ? nil : held
                layer.frame(width: hold?.width, height: hold?.height, alignment: .topLeading)
            }
    }
}
