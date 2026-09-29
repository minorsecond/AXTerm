//
//  BBSSettingsTab.swift
//  AXTerm
//

import SwiftUI

// The mailbox UI is macOS-only, like the window layout it lives in. The shell,
// the store and the service are platform-neutral, so an iOS view can be added
// later without touching anything below this layer.
#if os(macOS)

/// Mailbox settings, with a live preview of what a caller actually sees.
///
/// The preview is the point of this pane. The banner is the only thing the
/// station says about its own availability, and an operator writing it blind
/// has no way to judge it — seeing the greeting assembled, in the font it will
/// be sent in, is the difference between a banner that reads well on a 40-column
/// terminal and one that does not.
struct BBSSettingsTab: View {
    @ObservedObject var settings: BBSSettings
    let stationCallsign: String
    let isWinlinkP2PArmed: Bool

    /// True only when a call to the mailbox would *also* be answered by
    /// Winlink P2P. Two services on one radio are normal; the same address
    /// serving both is the misconfiguration.
    private var sharesAddressWithWinlink: Bool {
        guard isWinlinkP2PArmed else { return false }
        return PersonalBBSListener.answers(
            settings.effectiveCallsign(stationCallsign: stationCallsign),
            as: stationCallsign)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Answer calls", isOn: $settings.onAir)
                Text("A mailbox that answers transmits with nobody present. "
                     + "In the US that is automatic control, so it is off until you say otherwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if sharesAddressWithWinlink {
                    Label("Winlink P2P also answers as \(stationCallsign.uppercased()). "
                          + "Give the mailbox its own SSID below and both can run at once.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("On air")
            }

            Section {
                TextField("Mailbox callsign", text: $settings.callsign,
                          prompt: Text(stationCallsign.isEmpty ? "NOCALL" : stationCallsign))
                    .font(.system(.body, design: .monospaced))
                Text("Leave empty to answer as \(stationCallsign.isEmpty ? "your station callsign" : stationCallsign). "
                     + "Give the mailbox its own SSID when anything else answers to that "
                     + "address — Winlink P2P, a second AXTerm, or a node on this host. "
                     + "Separate SSIDs are how one radio runs several services at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Identity")
            }

            Section {
                TextEditor(text: $settings.banner)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                Text("Shown to every caller. This is the only place the mailbox "
                     + "says when you are around — it does not guess.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Greeting")
            }

            Section {
                TextEditor(text: $settings.stationInfo)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                Text("What `I` tells a caller — rig, antenna, what this mailbox is for.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Station info")
            }

            Section {
                Toggle("Answer J with what this station hears", isOn: $settings.publishHeardList)
                Text("A heard list is standard on a BBS, and the stations in it are "
                     + "transmitting on the same channel your caller is already listening "
                     + "to. It does say what this antenna reaches, which is a rough "
                     + "statement about where you are — so you can turn it off. "
                     + "Callers can also ask with MH or JHEARD, the BPQ and "
                     + "Kantronics spellings of the same question.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Answer WP with the caller directory", isOn: $settings.publishWhitePages)
                Text("White pages list the name, town and home BBS of everyone "
                     + "who has registered here — information they gave this "
                     + "station, republished to anyone who asks. Off answers "
                     + "honestly that the directory is not published.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Heard list")
            }

            Section {
                Picker("Disconnect after", selection: $settings.idleTimeout) {
                    Text("2 minutes").tag(TimeInterval(120))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("10 minutes").tag(TimeInterval(600))
                    Text("30 minutes").tag(TimeInterval(1800))
                }
                Text("A caller who stops typing should not hold the channel open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Idle")
            }

            Section {
                Label("Shared folders and uploads are set up in the BBS window, "
                      + "under Files — beside the files themselves.",
                      systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Files")
            }

            Section {
                preview
            } header: {
                Text("What a caller sees")
            }
        }
        .formStyle(.grouped)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color(platform: .platformTextBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .textSelection(.enabled)
    }

    /// Built by the real shell, not a mock-up of it, so the preview cannot
    /// drift away from what is transmitted. Shared with the iOS settings
    /// screen — see `BBSGreetingPreview`.
    private var previewLines: [String] {
        BBSGreetingPreview.lines(
            sysop: settings.effectiveCallsign(stationCallsign: stationCallsign),
            banner: settings.banner)
    }
}
#endif
