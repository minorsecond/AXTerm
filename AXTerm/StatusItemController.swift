//
//  StatusItemController.swift
//  AXTerm
//
//  The menu bar presence, owned by AppKit rather than SwiftUI's
//  MenuBarExtra.
//
//  Why not MenuBarExtra: its controller re-sets the status button's
//  image from `Update.dispatchActions`, which runs during EVERY window's
//  render flush — not just the menu's own. Each setImage invalidates
//  intrinsic size on the 32×24 status window, and a packet flood
//  producing several main-window render flushes in one display cycle
//  tripped AppKit's "more Update Constraints passes than views" guard,
//  which is thrown as an NSException that stalled the app (sampled live
//  2026-08-29, twice; the second sample showed the main thread inside
//  -[NSApplication _crashOnException:]). Slowing our own publishes and
//  decoupling the menu content both failed to stop it, because the
//  driver is the framework's own update dispatch. Owning the
//  NSStatusItem directly means the image is set exactly once and the
//  menu reads live state only at the moment it opens — pinned by
//  StatusItemControllerTests.
//

#if os(macOS)
import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    /// Retained for the life of the app; created in AXTermApp.init.
    static var shared: StatusItemController?

    private let client: PacketEngine
    private let settings: AppSettingsStore
    private let inspectionRouter: PacketInspectionRouter
    private let defaults: UserDefaults

    private var statusItem: NSStatusItem?
    /// Pinned by tests: exactly one for the life of the item.
    private(set) var buttonImageSetCount = 0
    var isInserted: Bool { statusItem != nil }

    init(client: PacketEngine,
         settings: AppSettingsStore,
         inspectionRouter: PacketInspectionRouter,
         defaults: UserDefaults = .standard) {
        self.client = client
        self.settings = settings
        self.inspectionRouter = inspectionRouter
        self.defaults = defaults
        super.init()

        // The status bar is not usable until the app finishes launching;
        // in tests (and any post-launch construction) sync immediately.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncInsertion() }
        }
        // The Settings toggle writes the same defaults key the old
        // MenuBarExtra(isInserted:) binding used — follow it live.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncInsertion() }
        }
        if NSApp != nil, NSApp.isRunning { syncInsertion() }
    }

    private func syncInsertion() {
        let wanted = defaults.object(forKey: AppSettingsStore.runInMenuBarKey) == nil
            ? AppSettingsStore.defaultRunInMenuBar
            : defaults.bool(forKey: AppSettingsStore.runInMenuBarKey)
        setInserted(wanted)
    }

    func setInserted(_ inserted: Bool) {
        if inserted {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right",
                accessibilityDescription: "AXTerm")
            buttonImageSetCount += 1
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Menu

    /// The pure half: what the menu says, derived from values so tests
    /// pin it without a status bar.
    enum MenuModel {
        static func statusTitle(for status: ConnectionStatus) -> String {
            switch status {
            case .connected: return "Connected"
            case .connecting: return "Connecting"
            case .disconnected: return "Disconnected"
            case .failed: return "Connection Failed"
            }
        }

        static func connectionAction(for status: ConnectionStatus) -> String {
            switch status {
            case .connected, .connecting: return "Disconnect"
            case .disconnected, .failed: return "Connect"
            }
        }
    }

    /// Live state is read here and nowhere else — when the operator
    /// opens the menu, never while it sits closed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = MenuModel.statusTitle(for: client.status)
        let host = client.connectedHost ?? settings.host
        let port = client.connectedPort.map(String.init) ?? String(settings.port)
        let header = NSMenuItem(
            title: "\(status) — \(host):\(port) • \(client.packets.count) packets",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(makeItem("Open AXTerm", #selector(openMainWindow)))
        let toggle = makeItem(MenuModel.connectionAction(for: client.status),
                              #selector(toggleConnection), key: "k")
        menu.addItem(toggle)
        menu.addItem(makeItem("Preferences…", #selector(openPreferences)))
        menu.addItem(.separator())

        let recent = Array(client.packets.suffix(10)).reversed()
        if !recent.isEmpty {
            let submenu = NSMenu()
            for packet in recent {
                let item = NSMenuItem(
                    title: "\(packet.fromDisplay) → \(packet.toDisplay) • \(packet.infoPreview)",
                    action: #selector(openPacket(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = packet.id
                submenu.addItem(item)
            }
            let parent = NSMenuItem(title: "Recent Packets", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
            menu.addItem(.separator())
        }

        #if DEBUG
        menu.addItem(makeItem("Send Test Event to Sentry", #selector(sendSentryTestEvent)))
        menu.addItem(.separator())
        #endif

        menu.addItem(makeItem("Quit AXTerm", #selector(quit)))
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = [.command] }
        return item
    }

    // MARK: - Actions

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let candidates = NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) }
        let main = candidates.first { $0.identifier?.rawValue.hasPrefix("main") == true }
            ?? candidates.first
        main?.makeKeyAndOrderFront(nil)
        inspectionRouter.consumeOpenWindowRequest()
    }

    @objc private func toggleConnection() {
        switch client.status {
        case .connected, .connecting:
            client.disconnect(reason: "user toggle connection (menu bar)")
        case .disconnected, .failed:
            client.connectUsingSettings()
        }
    }

    @objc private func openPreferences() {
        // The selector was renamed in macOS 13; try both spellings so
        // the item works wherever the deployment target lands.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPacket(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Packet.ID else { return }
        inspectionRouter.requestOpenPacket(id: id)
        openMainWindow()
    }

    @objc private func sendSentryTestEvent() {
        SentryManager.shared.sendTestEvent()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
#endif
