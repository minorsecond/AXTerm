import SwiftUI

/// Settings › Remote Control: signing in from the road, the devices paired
/// for it, the control commands and the radios they reach
/// (Docs/RemoteAccessPlan.md). The station's, not the mailbox's: the node
/// offers them too.
struct RemoteControlSettingsView: View {
    @ObservedObject var settings: BBSSettings
    /// The name the authenticator app shows for the code.
    let mailboxCallsign: String

    var body: some View {
        Form {
            Section {
                Text("Calling the mailbox or the node on your own callsign, you can sign in as the owner and "
                     + "read the station or change it with your control commands. Everything stays readable "
                     + "on the air: the code and the checks prove who you are without hiding anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OwnerAccessSection(settings: settings, mailboxCallsign: mailboxCallsign)
            if let codesLockedUntil {
                Section {
                    Text("Too many wrong codes: codes are refused until "
                         + codesLockedUntil.formatted(date: .abbreviated, time: .shortened)
                         + ". A paired device's key still signs in.")
                    Button("Clear Lockout") {
                        RemoteControlService.clearCodeLockout(by: "the operator at the station")
                        reload()
                    }
                } header: {
                    Text("Code lockout")
                } footer: {
                    Text("Each lockout after the first is twice as long, up to a week, until a right code. "
                         + "The wrong codes, and the path each came over, are in Recent activity.")
                }
            }
            if settings.ownerCommandsEnabled {
                OwnerControlSection(settings: settings)
            }
            Section {
                if log.isEmpty {
                    Text("Nothing yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(log.suffix(20).reversed()) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.text)
                        Text("\(event.caller) at the \(event.door), "
                             + event.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Refresh") { reload() }
                    .buttonStyle(.borderless)
            } header: {
                Text("Recent activity")
            } footer: {
                Text("Every sign-in, control command and fail-safe step, from the mailbox and the node.")
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
    }

    private func reload() {
        log = RemoteControlService.storedLog()
        codesLockedUntil = RemoteControlService.codeLockedUntil()
    }

    @State private var log: [RemoteControlService.Event] = []
    @State private var codesLockedUntil: Date?
}
