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
            if settings.ownerCommandsEnabled {
                OwnerControlSection(settings: settings)
            }
        }
        .formStyle(.grouped)
    }
}
