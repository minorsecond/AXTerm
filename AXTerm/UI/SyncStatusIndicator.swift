import SwiftUI
import Combine

/// A small toolbar indicator: is the mailbox synced, and when did it last
/// happen.
///
/// Deliberately quiet. It sits beside the TNC and adaptive chips and reports
/// one fact, because that is the fact an operator actually wants at a glance —
/// "is what I'm looking at also on my other radio, and how stale is that".
/// Everything else lives behind the tooltip.
///
/// Hidden entirely when sync is off. An indicator for a feature nobody turned
/// on is clutter, and a greyed-out cloud invites the question "is it broken?"
/// about something that is simply not enabled.
struct SyncStatusIndicator: View {

    @ObservedObject var sync: WinlinkSyncController
    /// Set false to hide the label and show only the glyph, for narrow
    /// toolbars.
    var showsLabel = true

    @State private var now = Date()
    /// Drives the relative time. One minute is enough: the label reads
    /// "2 min ago", so a finer tick would redraw without changing anything.
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        if case .disabled = sync.status {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                icon
                if showsLabel, let label = shortLabel {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.35), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { sync.syncNow() }
            .onReceive(tick) { now = $0 }
            .explain(tooltip, showsIndicator: false)
            .accessibilityLabel("iCloud sync")
            .accessibilityValue(sync.status.summary)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch sync.status {
        case .syncing:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 11, height: 11)
        case .failed:
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .unavailable:
            Image(systemName: "icloud.slash")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .idle(let report, _):
            // A filled cloud only once a pass has actually completed. An
            // outline before then says "on, but nothing has happened yet",
            // which is the truth and matters on a first run.
            Image(systemName: report == nil ? "icloud" : "checkmark.icloud.fill")
                .font(.system(size: 11))
                .foregroundStyle(report == nil ? Color.secondary : Color.green)
        case .disabled:
            EmptyView()
        }
    }

    /// Two or three characters where possible — this is a toolbar, not a
    /// status pane.
    private var shortLabel: String? {
        switch sync.status {
        case .disabled: return nil
        case .syncing: return "Syncing"
        case .unavailable: return "No iCloud"
        case .failed: return "Failed"
        case .idle(_, let at):
            guard let at else { return "Waiting" }
            return Self.relative(at, now: now)
        }
    }

    private var tooltip: String {
        var lines = [sync.status.detail]
        if case .idle(_, let at) = sync.status, let at {
            lines.insert("Last synced \(Self.relative(at, now: now)).", at: 0)
        }
        lines.append("Click to sync now. Sync also runs on launch, after every Winlink session, and every two minutes while the app is open.")
        return lines.joined(separator: "\n\n")
    }

    /// Compact relative time. `RelativeDateTimeFormatter` says "1 min ago";
    /// the toolbar has room for "1m", and the tooltip carries the full form.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<45: return "just now"
        case ..<3600: return "\(Int((seconds / 60).rounded()))m"
        case ..<86_400: return "\(Int((seconds / 3600).rounded()))h"
        default: return "\(Int((seconds / 86_400).rounded()))d"
        }
    }
}

// MARK: - Callsign collision

/// Warns that another station on this channel is transmitting under this
/// station's callsign.
///
/// Drawn as a banner rather than an alert because the condition persists: an
/// alert is dismissed and forgotten, while the underlying problem keeps
/// breaking every session until somebody changes an SSID. It stays until
/// dismissed, and comes back if the collision continues.
struct IdentityCollisionBanner: View {

    let collision: StationIdentityMonitor.Collision
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Another station is transmitting as \(collision.callsign)")
                    .font(.callout.weight(.medium))
                Text("Sessions will drop for no visible reason until one device uses a different SSID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Dismiss", action: onDismiss)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .explain(collision.explanation, showsIndicator: false)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
