//
//  BBSSettingsScreen.swift
//  AXTerm
//
//  Mailbox settings on a handheld, with the same live preview the Mac shows.
//

#if os(iOS)
import SwiftUI

/// What the *station* does: on air, identity, greeting, heard list, idle
/// timeout. Shared folders and uploads are in the Mailbox tab under Files,
/// beside the files themselves.
///
/// Pushed inside the Settings stack, so it owns no navigation of its own —
/// only its title.
struct BBSSettingsScreen: View {

    @ObservedObject var settings: BBSSettings
    let stationCallsign: String
    let isWinlinkP2PArmed: Bool

    /// True only when a call to the mailbox would *also* be answered by
    /// Winlink P2P. Two services on one radio are normal; the same address
    /// serving both is the misconfiguration, because the answering station
    /// speaks first in both protocols and nothing can tell what the caller
    /// wanted.
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

                if sharesAddressWithWinlink {
                    Label("Winlink P2P also answers as \(stationCallsign.uppercased()). "
                          + "Give the mailbox its own SSID below and both can run at once.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("On air")
            } footer: {
                Text("A mailbox that answers transmits with nobody present. In the US "
                     + "that is automatic control, so it is off until you say otherwise.")
            }

            Section {
                TextField("Mailbox callsign", text: $settings.callsign,
                          prompt: Text(stationCallsign.isEmpty ? "NOCALL" : stationCallsign))
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
            } header: {
                Text("Identity")
            } footer: {
                Text("Leave empty to answer as "
                     + "\(stationCallsign.isEmpty ? "your station callsign" : stationCallsign). "
                     + "Give the mailbox its own SSID when anything else answers to that "
                     + "address — Winlink P2P, a second AXTerm, or a node on this host. "
                     + "Separate SSIDs are how one radio runs several services at once.")
            }

            Section {
                TextEditor(text: $settings.banner)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
            } header: {
                Text("Greeting")
            } footer: {
                Text("Shown to every caller. This is the only place the mailbox says when "
                     + "you are around — it does not guess, predict or measure your hours.")
            }

            Section {
                TextEditor(text: $settings.stationInfo)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
            } header: {
                Text("Station info")
            } footer: {
                Text("What I tells a caller — rig, antenna, what this mailbox is for.")
            }

            Section {
                Toggle("Answer J with what this station hears",
                       isOn: $settings.publishHeardList)
                Text("A heard list is standard on a BBS, and the stations in it are "
                     + "transmitting on the same channel your caller is already listening "
                     + "to. It does say what this antenna reaches, which is a rough "
                     + "statement about where you are — so you can turn it off. Callers "
                     + "can also ask with MH or JHEARD, the BPQ and Kantronics spellings "
                     + "of the same question.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Answer WP with the caller directory",
                       isOn: $settings.publishWhitePages)
                Text("White pages list the name, town and home BBS of everyone who has "
                     + "registered here — information they gave this station, republished "
                     + "to anyone who asks. Off answers honestly that the directory is "
                     + "not published.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("What callers may ask for")
            }

            Section {
                Picker("Disconnect after", selection: $settings.idleTimeout) {
                    Text("2 minutes").tag(TimeInterval(120))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("10 minutes").tag(TimeInterval(600))
                    Text("30 minutes").tag(TimeInterval(1800))
                }
            } header: {
                Text("Idle")
            } footer: {
                Text("A caller who stops typing should not hold the channel open.")
            }

            Section {
                Label("Shared folders and uploads are in the Mailbox tab, under Files — "
                      + "beside the files themselves.",
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
            } footer: {
                Text("Assembled by the same shell that transmits it, so this cannot drift "
                     + "from what actually goes out.")
            }

            Section {
                Label("On iPhone and iPad the mailbox answers only while AXTerm is in the "
                      + "foreground. When the app leaves the screen, open sessions get a "
                      + "closing line and a DISC rather than silence — a caller whose "
                      + "station vanishes mid-session retries into an address that "
                      + "stopped existing.",
                      systemImage: "iphone.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("While this app is asleep")
            }
        }
        .navigationTitle("Mailbox")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Monospaced and narrow, because that is the shape a caller reads it in.
    private var preview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .background(Color(platform: .platformTextBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .textSelection(.enabled)
    }

    private var previewLines: [String] {
        BBSGreetingPreview.lines(
            sysop: settings.effectiveCallsign(stationCallsign: stationCallsign),
            banner: settings.banner)
    }
}
#endif
