import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pointer and gesture vocabulary for the network graph, named once so the
/// graph's interaction logic does not know which platform it is running on.
///
/// The graph is the one surface where the two platforms genuinely differ in
/// *kind* rather than in spelling. A Mac has a pointer that hovers, a
/// scroll wheel, a right-click and modifier keys; a touch screen has none of
/// those and has direct manipulation instead. Both must reach the same
/// behaviour — select, multi-select, pan, zoom, act on a node — so the
/// difference is confined to how the intent arrives, not to what it means.

// MARK: - Modifiers

/// Modifier keys, where there are any.
///
/// On iOS these come from a hardware keyboard when one is attached (an iPad
/// with a Magic Keyboard is a real target for this app) and are empty
/// otherwise. Code that reads them must therefore always have a
/// no-modifier path that still works.
nonisolated struct GraphInputModifiers: OptionSet, Sendable {
    let rawValue: Int

    static let shift = GraphInputModifiers(rawValue: 1 << 0)
    /// Command on macOS and iPadOS alike.
    static let command = GraphInputModifiers(rawValue: 1 << 1)
    static let option = GraphInputModifiers(rawValue: 1 << 2)
    static let control = GraphInputModifiers(rawValue: 1 << 3)

    /// True when the gesture means "add to the selection rather than replace
    /// it" — shift or command, following both platforms' conventions.
    var isAdditive: Bool { contains(.shift) || contains(.command) }

    #if os(macOS)
    init(_ flags: NSEvent.ModifierFlags) {
        var value: GraphInputModifiers = []
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        self = value
    }
    #else
    init(_ flags: UIKeyModifierFlags) {
        var value: GraphInputModifiers = []
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.alternate) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        self = value
    }
    #endif

    init(rawValue: Int) { self.rawValue = rawValue }
}

// MARK: - Context actions

/// One entry in the graph's node menu.
///
/// Modelled rather than built, so the same list becomes an `NSMenu` on macOS
/// and a SwiftUI context menu on iOS. Building AppKit menus inside the
/// coordinator would have made the menu macOS-only for no reason — the
/// *actions* are identical, only the presentation differs.
nonisolated struct GraphContextAction: Identifiable, Sendable {
    enum Kind: Sendable {
        case normal
        case separator
        /// Reverses something already in effect; drawn destructively.
        case destructive
    }

    let id: String
    let title: String
    var kind: Kind = .normal
    /// Nil for a separator.
    var perform: (@MainActor @Sendable () -> Void)?

    static func separator(_ id: String) -> GraphContextAction {
        GraphContextAction(id: id, title: "", kind: .separator, perform: nil)
    }
}

/// A menu for one node.
nonisolated struct GraphContextMenu: Sendable {
    let nodeID: String
    let callsign: String
    let actions: [GraphContextAction]
}

#if os(macOS)

extension GraphContextMenu {
    /// Renders as an AppKit menu.
    ///
    /// Each item keeps its closure alive in its representedObject target, so
    /// the menu works without the coordinator having to own a selector per
    /// action.
    @MainActor
    func makeNSMenu() -> NSMenu {
        let menu = NSMenu(title: "Node Actions")
        for action in actions {
            if case .separator = action.kind {
                menu.addItem(.separator())
                continue
            }
            let target = GraphMenuActionTarget(action.perform)
            let item = NSMenuItem(title: action.title,
                                  action: #selector(GraphMenuActionTarget.fire),
                                  keyEquivalent: "")
            item.target = target
            // The item owns its target; without this the closure is released
            // as soon as this function returns and the menu does nothing.
            item.representedObject = target
            menu.addItem(item)
        }
        return menu
    }
}

@MainActor
private final class GraphMenuActionTarget: NSObject {
    private let action: (@MainActor @Sendable () -> Void)?
    init(_ action: (@MainActor @Sendable () -> Void)?) { self.action = action }
    @objc func fire() { action?() }
}

#endif

// MARK: - SwiftUI presentation

/// The same menu as SwiftUI buttons, for platforms with no `NSMenu`.
struct GraphContextMenuButtons: View {
    let menu: GraphContextMenu

    var body: some View {
        ForEach(menu.actions) { action in
            switch action.kind {
            case .separator:
                Divider()
            case .normal:
                Button(action.title) { action.perform?() }
            case .destructive:
                Button(action.title, role: .destructive) { action.perform?() }
            }
        }
    }
}
