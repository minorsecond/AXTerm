import SwiftUI

/// Settings → Winlink: station location, account credentials, CMS key,
/// and exchange preferences.
struct WinlinkSettingsTab: View {

    @ObservedObject var settings: WinlinkSettings

    @State private var passwordDraft = ""
    @State private var apiKeyDraft = ""
    @State private var didLoadSecrets = false

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Grid square", text: $settings.gridSquare, prompt: Text("e.g. DM79lr"))
                        .frame(maxWidth: 160)
                    if settings.gridSquare.isEmpty {
                        Text("required for the station list")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if Maidenhead.isValid(settings.gridSquare) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            .help("Not a valid Maidenhead locator (4, 6 or 8 characters, e.g. DM79 or DM79lr).")
                    }
                }
                .help(WinlinkCopy.gridSquareTooltip)

                Stepper(value: $settings.maxDistanceMiles, in: 0...1000, step: 25) {
                    HStack {
                        Text("Station search radius")
                        Spacer()
                        Text(settings.maxDistanceMiles == 0 ? "unlimited" : "\(settings.maxDistanceMiles) mi")
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Maximum distance for the nearby-gateway search. 0 means no limit.")

                Stepper(value: $settings.historyHours, in: 1...48, step: 1) {
                    HStack {
                        Text("Only gateways seen within")
                        Spacer()
                        Text("\(settings.historyHours) h").foregroundStyle(.secondary)
                    }
                }
                .help("Filters the station list to gateways that reported to the CMS within this window — silent gateways are probably off the air.")
            } header: {
                Text("Station")
            }

            Section {
                SecureField("Winlink password", text: $passwordDraft)
                    .onChange(of: passwordDraft) { newValue in
                        guard didLoadSecrets else { return }
                        settings.password = newValue
                    }
                    .help(WinlinkCopy.passwordTooltip)

                SecureField("CMS access key (optional)", text: $apiKeyDraft)
                    .onChange(of: apiKeyDraft) { newValue in
                        guard didLoadSecrets else { return }
                        settings.apiKeyOverride = newValue
                    }
                    .help(WinlinkCopy.apiKeyTooltip)

                Text("Both are stored in the macOS Keychain, never in preferences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Account")
            }

            Section {
                TextField("Preferred gateway", text: $settings.gatewayCallsign, prompt: Text("e.g. KE7XO-10"))
                    .frame(maxWidth: 200)
                    .help("The RMS gateway Connect & Exchange uses. Usually set from the Stations list.")

                TextField("Digipeater path", text: $settings.gatewayPath, prompt: Text("optional, e.g. WIDE1-1"))
                    .frame(maxWidth: 200)
                    .help("Optional comma-separated digipeater path to reach the gateway.")

                Picker("Preferred transport", selection: $settings.preferredTransport) {
                    Text("Packet (AX.25)").tag(WinlinkSettings.TransportPreference.ax25)
                    Text("Telnet (Internet)").tag(WinlinkSettings.TransportPreference.telnet)
                }
                .frame(maxWidth: 280)
                .help(WinlinkCopy.transportTooltip)
            } header: {
                Text("Mail Exchange")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            passwordDraft = settings.password
            apiKeyDraft = settings.apiKeyOverride
            didLoadSecrets = true
        }
    }
}
