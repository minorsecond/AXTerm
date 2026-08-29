//
//  MenuBarView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import SwiftUI
import Combine

struct MenuBarView: View {
    /// Deliberately NOT @ObservedObject. The menu content view is always
    /// mounted, and observing the packet engine re-rendered it on every
    /// received packet; each render re-set the status item's button
    /// image, and a burst of packets in one display cycle tripped
    /// AppKit's update-constraints loop guard on the status bar window —
    /// thrown as an NSException that killed the app (sampled live
    /// 2026-08-29 06:30: main thread in -[NSApplication
    /// _crashOnException:] via MenuBarExtraController.updateButton).
    /// The pulse below re-renders this menu at most every five seconds,
    /// and only when what it displays actually changed.
    let client: PacketEngine
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var inspectionRouter: PacketInspectionRouter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// The slow clock that stands in for live observation.
    @StateObject private var pulse = MenuBarPulse()
    @MainActor final class MenuBarPulse: ObservableObject {
        @Published var fingerprint = ""
    }

    var body: some View {
        VStack(alignment: .leading) {
            statusSection
            Divider()
            Button("Open AXTerm") {
                openMainWindow()
            }

            Button(connectionActionTitle) {
                toggleConnection()
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button("Preferences…") {
                openPreferences()
            }
            Divider()

            if !recentPackets.isEmpty {
                Menu("Recent Packets") {
                    ForEach(recentPackets) { packet in
                        Button(action: {
                            inspectionRouter.requestOpenPacket(id: packet.id)
                        }) {
                            Text("\(packet.fromDisplay) → \(packet.toDisplay) • \(packet.infoPreview)")
                        }
                    }
                }
                Divider()
            }

            Button("Quit AXTerm") {
                NSApp.terminate(nil)
            }
        }
        .task(id: inspectionRouter.shouldOpenMainWindow) {
            guard inspectionRouter.shouldOpenMainWindow else { return }
            await handleOpenWindowRequest()
        }
        .task {
            while !Task.isCancelled {
                let now = "\(client.status)|\(client.packets.count)|"
                    + "\(client.connectedHost ?? "")|\(client.connectedPort ?? 0)"
                if pulse.fingerprint != now { pulse.fingerprint = now }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusTitle)
                .font(.headline)
            Text("\(connectionDetail) • \(client.packets.count) packets")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var statusTitle: String {
        switch client.status {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Connection Failed"
        }
    }

    private var connectionDetail: String {
        let host = client.connectedHost ?? settings.host
        let port = client.connectedPort.map(String.init) ?? String(settings.port)
        return "\(host):\(port)"
    }

    private var connectionActionTitle: String {
        switch client.status {
        case .connected, .connecting:
            return "Disconnect"
        case .disconnected, .failed:
            return "Connect"
        }
    }

    private var recentPackets: [Packet] {
        Array(client.packets.suffix(10)).reversed()
    }

    private func toggleConnection() {
        switch client.status {
        case .connected, .connecting:
            client.disconnect(reason: "user toggle connection (menu bar)")
        case .disconnected, .failed:
            client.connectUsingSettings()
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func handleOpenWindowRequest() async {
        // Ensure this happens outside of SwiftUI's view-update transaction.
        await Task.yield()
        openMainWindow()
        inspectionRouter.consumeOpenWindowRequest()
    }

    private func openPreferences() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    MenuBarView(
        client: PacketEngine(settings: AppSettingsStore()),
        settings: AppSettingsStore(),
        inspectionRouter: .shared
    )
}
