//
//  BBSView.swift
//  AXTerm
//

import SwiftUI

// The mailbox UI is macOS-only, like the window layout it lives in. The shell,
// the store and the service are platform-neutral, so an iOS view can be added
// later without touching anything below this layer.
#if os(macOS)

/// The personal mailbox.
struct BBSView: View {
    @ObservedObject var service: BBSService
    @ObservedObject var settings: BBSSettings
    @ObservedObject var library: BBSFileLibrary
    let stationCallsign: String
    /// Other instances' mailboxes, read-only. Nil where mailbox sharing is
    /// off or the database could not be opened, and then every pane here
    /// behaves exactly as it did before there was such a thing.
    var remoteMailbox: BBSMailboxReplicationStore?

    /// Chosen in the sidebar, which is where this page's navigation lives
    /// now. The segmented picker that used to sit across the top was a
    /// second row of navigation inside a page that already had one beside it.
    @Binding var pane: BBSPane

    private var sysop: String {
        settings.effectiveCallsign(stationCallsign: stationCallsign)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !service.isAvailable {
                unavailable
            } else {
            BBSStatusHeader(service: service, settings: settings)
            Divider()

            // Ticks only while it has something to count.
            if service.live != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    BBSLiveCallPanel(service: service, now: context.date)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            switch pane {
            case .messages:
                BBSMessagesPane(service: service, sysop: sysop,
                                remoteMailbox: remoteMailbox)
            case .callers:
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    BBSCallersPane(service: service, now: context.date,
                                   remoteMailbox: remoteMailbox)
                }
            case .directory:
                BBSDirectoryPane(service: service)
            case .files:
                BBSFilesPane(library: library, settings: settings,
                             bytesPerSecond: service.linkThroughput)
            }

            }

            if let storeError = service.storeError {
                Label(storeError, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: service.live)
        .onAppear { service.reload() }
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Mailbox unavailable").font(.headline)
            Text("The AXTerm database could not be opened, so the mailbox "
                 + "cannot keep what callers leave and will not answer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
