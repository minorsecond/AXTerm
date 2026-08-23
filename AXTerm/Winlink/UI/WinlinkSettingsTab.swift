import SwiftUI

/// Settings → Winlink: station location, account credentials, CMS key,
/// and exchange preferences.
struct WinlinkSettingsTab: View {

    @ObservedObject var settings: WinlinkSettings
    @ObservedObject var profile: StationProfile

    @State private var passwordDraft = ""
    @State private var apiKeyDraft = ""
    @State private var didLoadSecrets = false
    @State private var isVerifyingKey = false
    @State private var keyVerification: (ok: Bool, message: String)?

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
                TextField("Name", text: $profile.realName, prompt: Text("e.g. Jane Doe"))
                TextField("Position / title", text: $profile.positionTitle, prompt: Text("e.g. EC, Net Control"))
                TextField("Organization", text: $profile.organization, prompt: Text("e.g. ARES District 3"))
                TextField("Phone", text: $profile.phone)
                TextField("Email", text: $profile.email)
            } header: {
                Text("Operator")
            } footer: {
                Text("Auto-fills Winlink forms (ICS-213 sender, Check-in contact, Severe WX reporting party…) and signatures. Your Winlink account password is only a credential — the network never shares identity details, so these fields are the source of truth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Street", text: $profile.street)
                TextField("City", text: $profile.city)
                HStack {
                    TextField("State", text: $profile.state)
                        .frame(maxWidth: 90)
                    TextField("ZIP", text: $profile.postalCode)
                        .frame(maxWidth: 110)
                    TextField("County", text: $profile.county)
                }
            } header: {
                Text("Address")
            } footer: {
                Text("Used by welfare and situation-report forms (city, county and state fields).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Winlink password", text: $passwordDraft)
                    .onChange(of: passwordDraft) { newValue in
                        guard didLoadSecrets else { return }
                        settings.password = newValue
                    }
                    .help(WinlinkCopy.passwordTooltip)

                HStack {
                    SecureField("CMS access key (optional)", text: $apiKeyDraft)
                        .onChange(of: apiKeyDraft) { newValue in
                            guard didLoadSecrets else { return }
                            settings.apiKeyOverride = newValue
                            keyVerification = nil
                        }
                        .help(WinlinkCopy.apiKeyTooltip)

                    Button {
                        verifyAPIKey()
                    } label: {
                        if isVerifyingKey {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Verify")
                        }
                    }
                    .disabled(isVerifyingKey || apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Checks the key against the Winlink catalog service — the operation that needs a personal key.")
                }

                if let verification = keyVerification {
                    Label(verification.message, systemImage: verification.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(verification.ok ? .green : .red)
                }

                Text("Both are stored in the macOS Keychain, never in preferences. A personal key unlocks the internet catalog refresh (the built-in community key only covers the station list) — request one from the Winlink development team, ideally together with registering AXTerm as a client type.")
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

                Picker("Identify as", selection: $settings.clientProduct) {
                    Text("AXTerm").tag("AXTerm")
                    Text("Pat (registered client)").tag("Pat")
                }
                .frame(maxWidth: 280)
                .help("The client name sent in the B2F handshake. The production Winlink CMS only accepts registered client types — until AXTerm is registered with the Winlink development team, gateways will reply 'Unknown client types are not allowed' and disconnect. Selecting Pat (an open-source client with the same B2F feature set) is the community's usual workaround while a registration request is pending.")

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

    /// Tests the entered key against the catalog operation (the one that
    /// requires a personal key) and reports the outcome inline.
    private func verifyAPIKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        isVerifyingKey = true
        keyVerification = nil
        Task { @MainActor in
            defer { isVerifyingKey = false }
            do {
                let items = try await WinlinkCMSClient(accessKey: key).inquiriesCatalog()
                keyVerification = (true, "Key accepted — catalog access works (\(items.count) items).")
            } catch let WinlinkCMSError.serviceError(message) {
                keyVerification = (false, "The CMS rejected the key: \(message)")
            } catch {
                keyVerification = (false, "Could not verify: \(RMSStationsViewModel.describe(error))")
            }
        }
    }
}
