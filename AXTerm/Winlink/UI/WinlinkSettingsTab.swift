import SwiftUI

/// Settings → Winlink: station location, account credentials, CMS key,
/// and exchange preferences.
struct WinlinkSettingsTab: View {

    @ObservedObject var settings: WinlinkSettings
    @ObservedObject var profile: StationProfile
    /// Shows what an empty listen callsign resolves to, and names the
    /// account the password is verified against.
    var stationCallsign: String = ""

    @State private var passwordDraft = ""
    @State private var apiKeyDraft = ""
    @State private var didLoadSecrets = false
    @State private var isVerifyingKey = false
    @State private var keyVerification: (ok: Bool, message: String)?
    @State private var newLadderCallsign = ""
    @State private var passwordStatus: PasswordStatus = .idle
    @State private var isVerifyingPassword = false
    @FocusState private var passwordFieldFocused: Bool

    /// What is known about the password in the box — kept apart from
    /// what is known about the password on the account.
    ///
    /// The old UI collapsed the two: it wrote the Keychain on every
    /// keystroke and showed a green tick for a successful read-back, so a
    /// half-typed password looked verified. Only the CMS can produce
    /// `.verified`.
    private enum PasswordStatus: Equatable {
        case idle
        case stored
        case storeFailed
        case verified(Date)
        case refused(String)
        case unknown(String)
    }

    /// Optional so the tab still previews and builds without a location
    /// service wired in.
    var locationService: StationLocationService?
    /// How far a ladder rung is, when the gateway cache knows. Supplied
    /// rather than looked up here: Settings is its own scene and has no
    /// station view model, and inventing one to answer a decoration would be
    /// a lot of machinery for a caption.
    var stationDistanceMiles: (String, Int?) -> Double? = { _, _ in nil }
    /// Nil when the database failed to open — no mailbox, nothing to sync.
    var sync: WinlinkSyncController?
    @State private var isLocating = false
    @State private var locationNote: String?
    @State private var locationNoteIsError = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Button {
                        Task { await fillFromCurrentPosition() }
                    } label: {
                        if isLocating {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Use My Current Position", systemImage: "location.fill")
                        }
                    }
                    .disabled(isLocating || locationService == nil)
                    .help("Sets the grid square from GPS \u{2014} pure arithmetic on the fix, so it works with everything else down \u{2014} and fills city, state, county and ZIP from a reverse lookup, which does need the internet.")
                    Spacer()
                }
                if let locationNote {
                    Label(locationNote, systemImage: locationNoteIsError
                          ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(locationNoteIsError ? .orange : .secondary)
                }
            } header: {
                Text("Position")
            } footer: {
                Text("Fills the grid square and address below. The grid square comes from the GPS fix alone; the postal address needs a network lookup, so do it while you have a path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Callsign directory") {
                // The control moved to General → Online: it gates the
                // map's and node directory's lookups too, and a
                // non-Winlink operator was never going to find it here.
                LabeledContent("Online callsign lookups") {
                    Text(settings.callsignLookupEnabled ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
                Text("Controlled in General settings — it gates every automatic position lookup in the app, not just Winlink\u{2019}s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Unified mailbox") {
                Toggle("Sync mail across my devices via iCloud", isOn: $settings.mailboxSyncEnabled)
                    .help("Shares this mailbox with your other devices signed into the same Apple Account, so mail worked on the home rig is readable on a handheld and read flags follow you.\n\nOff by default: sync sends your Winlink traffic to Apple's servers, which is a decision to make deliberately rather than inherit from an upgrade. It goes to your private database, which only you can read.\n\nMessages, read flags, folders, contacts, starred catalog products and callsign lookups travel. Digipeater paths, the gateway ladder, session logs and grid square do NOT \u{2014} those describe this antenna at this location, and are wrong anywhere else.")

                if settings.mailboxSyncEnabled {
                    Toggle("Share what this station hears", isOn: $settings.shareStationActivity)
                        .explain("Publishes a summary of the stations this receiver hears \u{2014} callsign, how often, how much airtime \u{2014} so your other stations can see what this one worked while they were away. It appears there under \u{201C}Other Stations\u{201D}, labelled with the station and grid square that heard it.\n\nIt is never merged into routing metrics. A packet this antenna heard says nothing about what a handheld across town can reach, and folding the two together would produce link quality describing neither.\n\nOff by default: it tells iCloud which stations you can hear, which is a rough statement about where you are and when you are on the air.")
                }

                if settings.mailboxSyncEnabled, let sync {
                    SyncStatusRow(sync: sync)
                }
            }

            Section("Peer-to-peer (grid-down)") {
                Toggle("Answer inbound Winlink calls", isOn: $settings.p2pListenEnabled)
                    .help("Lets other stations connect directly to you and exchange mail with no gateway, no CMS, and no internet — the mode that still works when infrastructure is gone.\n\nOff by default: an armed station accepts mail from anyone who calls and transmits in reply with no operator present. Arm it for an activation, not for everyday operating.")
                if settings.p2pListenEnabled {
                    Label("Armed \u{2014} this station answers inbound Winlink calls and will transmit in reply.",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    TextField("Answer on callsign", text: $settings.p2pListenCallsign,
                              prompt: Text(stationCallsign.isEmpty ? "your station callsign"
                                           : stationCallsign.uppercased()))
                        .font(.system(.body, design: .monospaced))
                    Text("Leave empty to answer as \(stationCallsign.isEmpty ? "your station callsign" : stationCallsign.uppercased()). "
                         + "Give the listener its own SSID to share the radio with another service — "
                         + "the mailbox, or a node on this host. Callers pick a service by the "
                         + "callsign they dial.\n\nThis is an address, not an identity: your Winlink "
                         + "account and the callsign carried in the mail exchange are unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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

                AntennaHeightField(title: "Antenna height above ground",
                                   metres: $settings.antennaHeightMetres,
                                   isFeet: $settings.heightUnitIsFeet)
                    .help(WinlinkCopy.antennaHeightTooltip)

                AntennaHeightField(title: "Assume for other stations",
                                   metres: $settings.assumedRemoteHeightMetres,
                                   isFeet: $settings.heightUnitIsFeet)
                    .help(WinlinkCopy.assumedHeightTooltip)

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
                HStack {
                    // Committed on Return or when the field loses focus,
                    // never per keystroke: the Keychain must hold the
                    // account password, not whatever half of it has been
                    // typed so far.
                    SecureField("Winlink password", text: $passwordDraft)
                        .focused($passwordFieldFocused)
                        .onSubmit { commitPassword() }
                        .onChange(of: passwordFieldFocused) { _, focused in
                            if !focused { commitPassword() }
                        }
                        .help(WinlinkCopy.passwordTooltip)

                    if let icon = passwordStatusIcon {
                        Image(systemName: icon.symbol)
                            .foregroundStyle(icon.tint)
                            .help(icon.help)
                    }

                    Button {
                        verifyPassword()
                    } label: {
                        if isVerifyingPassword {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Verify")
                        }
                    }
                    .disabled(isVerifyingPassword
                              || passwordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Asks the CMS whether this is the password on the account — the same question the ;PR: handshake asks on the air, answered here in a sentence instead of a disconnect.")
                }

                if let note = passwordStatusNote {
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(note.tint)
                }

                HStack {
                    SecureField("CMS access key (optional)", text: $apiKeyDraft)
                        .onChange(of: apiKeyDraft) { _, newValue in
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
                if settings.gatewayLadder.isEmpty {
                    Text("No gateways yet — add stations from the Stations tab (star button) or type a callsign below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(settings.gatewayLadder.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 8) {
                            Image(systemName: index == 0 ? "star.fill" : "\(index + 1).circle")
                                .foregroundStyle(index == 0 ? .yellow : .secondary)
                                .frame(width: 20)
                                .help(index == 0 ? "Primary gateway — tried first." : "Rung #\(index + 1).")
                            Text(entry.callsign)
                                .font(.body.monospaced())
                            if let hz = entry.frequencyHz {
                                Text(String(format: "%.3f MHz", Double(hz) / 1_000_000))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            // A rung carried home from a trip is legitimate
                            // but wasteful: the ladder would spend a whole
                            // call attempt on something hundreds of miles
                            // away. Naming the distance beats making the
                            // operator cross-reference two screens.
                            if let miles = ladderDistanceMiles(entry), miles > 150 {
                                Label(String(format: "%.0f mi", miles),
                                      systemImage: "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help("This gateway is \(Int(miles)) miles away — likely added for a trip. It stays in the ladder until removed, and every exchange from here will spend an attempt on it.")
                            }
                            if !entry.path.isEmpty {
                                Text("via \(entry.path)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                settings.moveInLadder(entryID: entry.id, up: true)
                            } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                                .help("Move up the ladder (tried earlier)")
                            Button {
                                settings.moveInLadder(entryID: entry.id, up: false)
                            } label: { Image(systemName: "chevron.down") }
                                .disabled(index == settings.gatewayLadder.count - 1)
                                .help("Move down the ladder (tried later)")
                            Button {
                                settings.removeFromLadder(entryID: entry.id)
                            } label: { Image(systemName: "minus.circle") }
                                .help("Remove from the ladder")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("Add gateway", text: $newLadderCallsign, prompt: Text("e.g. K0NTS-10"))
                        .frame(maxWidth: 160)
                        .onSubmit(addLadderEntry)
                    Button("Add", action: addLadderEntry)
                        .disabled(newLadderCallsign.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                TextField("Digipeater path", text: $settings.gatewayPath, prompt: Text("optional, e.g. WIDE1-1"))
                    .frame(maxWidth: 200)
                    .help("Optional comma-separated digipeater path, applied when exchanging with ladder gateways.")

                Picker("Identify as", selection: $settings.clientProduct) {
                    Text("AXTerm").tag("AXTerm")
                    Text("Pat (registered client)").tag("Pat")
                }
                .frame(maxWidth: 280)
                .help("The client name sent in the B2F handshake. The production Winlink CMS only accepts registered client types — until AXTerm is registered with the Winlink development team, gateways will reply 'Unknown client types are not allowed' and disconnect. Selecting Pat (an open-source client with the same B2F feature set) is the community's usual workaround while a registration request is pending.")

                Toggle("Ask which messages to download", isOn: $settings.askBeforeDownloading)
                    .help("A gateway proposes its mail before sending it. With this on, you see the subjects, senders and airtime and choose; with it off, everything it offers comes down.")

                if settings.askBeforeDownloading {
                    HStack {
                        Text("Download anyway if under")
                        TextField("", value: $settings.downloadAnywayUnderKB, format: .number)
                            .frame(maxWidth: 60)
                            .multilineTextAlignment(.trailing)
                        Text("KB")
                    }
                    .help("Applied only when the picker times out unanswered.")

                    Text("You get \(WinlinkSettings.inboundSelectionTimeout) seconds to choose, with the link open. Unanswered, messages under the size above download and the rest stay on the server — emergency traffic is small, and an unattended station should not commit a shared channel to a bulletin. Nothing you skip is ever lost; the gateway offers it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
            passwordStatus = initialPasswordStatus()
        }
    }

    private func addLadderEntry() {
        let callsign = newLadderCallsign.trimmingCharacters(in: .whitespaces)
        guard !callsign.isEmpty else { return }
        settings.addToLadder(callsign: callsign)
        newLadderCallsign = ""
    }

    /// Distance to a ladder rung, when the gateway cache knows it.
    private func ladderDistanceMiles(_ entry: WinlinkSettings.GatewayLadderEntry) -> Double? {
        stationDistanceMiles(entry.callsign, entry.frequencyHz)
    }

    // MARK: - Password

    /// The state to show when the pane opens: whatever the CMS last said
    /// about the password that is actually stored.
    private func initialPasswordStatus() -> PasswordStatus {
        guard !settings.password.isEmpty else { return .idle }
        if let verifiedAt = settings.passwordVerifiedAt { return .verified(verifiedAt) }
        return .stored
    }

    /// Writes the field to the Keychain. Called on Return and on focus
    /// loss, so a password is stored once, whole — an abandoned edit
    /// leaves the working password alone.
    private func commitPassword() {
        guard didLoadSecrets else { return }
        let trimmed = passwordDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        // Clearing the field is a real instruction; a half-typed one never
        // gets here, because nothing commits mid-edit.
        //
        // Only what gets stored is trimmed — the box is left as typed.
        // Rewriting it under the cursor is startling, and the dirty check
        // trims both sides anyway, so stray spaces do not read as an edit.
        guard !trimmed.isEmpty else {
            if !settings.password.isEmpty { settings.password = "" }
            passwordStatus = .idle
            return
        }

        // Same password as before: an abandoned edit, or a retype of the
        // one already stored. Either way the standing verdict still applies.
        guard trimmed != settings.password else { return }

        passwordStatus = settings.storePassword(trimmed) ? .stored : .storeFailed
    }

    /// Asks the CMS the question the air link will ask later.
    private func verifyPassword() {
        commitPassword()
        let password = settings.password
        guard !password.isEmpty else { return }

        let callsign = accountCallsign
        guard !callsign.isEmpty else {
            passwordStatus = .unknown("Set the station callsign first — the CMS checks a password against an account.")
            return
        }

        isVerifyingPassword = true
        Task { @MainActor in
            defer { isVerifyingPassword = false }
            do {
                // Built here rather than injected so an access key typed
                // in the field below counts immediately, exactly like the
                // key's own Verify button.
                let client = WinlinkCMSClient(accessKey: settings.effectiveAPIKey)
                let verdict = try await client.validatePassword(
                    callsign: callsign, password: password)
                switch verdict {
                case .accepted:
                    let now = Date()
                    settings.markPasswordVerified(at: now)
                    passwordStatus = .verified(now)
                case .rejected:
                    settings.markPasswordUnverified()
                    passwordStatus = .refused("The CMS says this is not the password on \(callsign). This is exactly what a session would hit: “Secure login failed - account password does not match”. Note it is case-sensitive. Reset it at winlink.org if you are unsure.")
                case .noSuchAccount:
                    settings.markPasswordUnverified()
                    passwordStatus = .refused("Winlink has no account for \(callsign). Check the station callsign — an SSID is ignored here, accounts belong to the base call.")
                case .accountBlocked:
                    settings.markPasswordUnverified()
                    passwordStatus = .refused("The Winlink account \(callsign) is locked out. Sort that out at winlink.org; no client can log in until it is.")
                }
            } catch let WinlinkCMSError.serviceError(message) {
                passwordStatus = .unknown("The CMS would not answer: \(message). The password is stored — this says nothing about whether it is right.")
            } catch {
                passwordStatus = .unknown("Could not reach the CMS: \(RMSStationsViewModel.describe(error)). The password is stored — this says nothing about whether it is right.")
            }
        }
    }

    /// Winlink accounts belong to the base callsign; the SSID we connect
    /// with is not part of the account.
    private var accountCallsign: String {
        Callsign(stationCallsign)?.base ?? ""
    }

    /// The box says something other than what is stored. Derived rather
    /// than tracked: a flag set from an `onChange` races the assignment
    /// that loads the field, and would open the pane claiming an edit.
    private var passwordIsDirty: Bool {
        guard didLoadSecrets else { return false }
        return passwordDraft.trimmingCharacters(in: .whitespacesAndNewlines) != settings.password
    }

    private var passwordStatusIcon: (symbol: String, tint: Color, help: String)? {
        if passwordIsDirty {
            return ("pencil.circle", .secondary,
                    "Not saved yet — press Return, or click outside the field.")
        }
        switch passwordStatus {
        case .idle:
            return nil
        case .stored:
            return ("questionmark.circle", .secondary,
                    "Stored in the Keychain. Nobody has asked Winlink whether it is right — press Verify.")
        case .storeFailed:
            return ("exclamationmark.triangle.fill", .red,
                    "The Keychain refused to store or return the password — see below.")
        case .verified:
            return ("checkmark.circle.fill", .green,
                    "The CMS confirmed this is the password on the account.")
        case .refused:
            return ("xmark.circle.fill", .red, "The CMS refused this password — see below.")
        case .unknown:
            return ("questionmark.circle", .orange,
                    "Stored, but the CMS could not be asked — see below.")
        }
    }

    private var passwordStatusNote: (text: String, tint: Color)? {
        if passwordIsDirty { return nil }
        switch passwordStatus {
        case .idle:
            return nil
        case .stored:
            return ("Stored in the Keychain, but never checked against Winlink. Press Verify — a wrong password only shows up as a refused session otherwise.", .secondary)
        case .storeFailed:
            return ("The password could not be saved to the Keychain (or was saved but can't be read back). This usually happens with development builds after re-signing. Try: quit and relaunch AXTerm, then re-enter it. If it persists, delete the old entry in Keychain Access (search “com.axterm.winlink”) and enter the password again.", .red)
        case .verified(let date):
            return ("Winlink accepted this password on \(date.formatted(date: .abbreviated, time: .shortened)).", .green)
        case .refused(let message):
            return (message, .red)
        case .unknown(let message):
            return (message, .orange)
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

    // MARK: - Position

    /// Two halves with different dependencies, and the UI says which is
    /// which: the grid square is arithmetic on the fix and always works,
    /// the postal address is a network lookup and does not.
    private func fillFromCurrentPosition() async {
        guard let locationService else { return }
        isLocating = true
        locationNote = nil
        locationNoteIsError = false
        defer { isLocating = false }

        guard let location = await locationService.currentLocation() else {
            locationNote = "No position available. Check Location permission in System Settings, or set a grid square by hand."
            locationNoteIsError = true
            return
        }

        if let grid = Maidenhead.locator(
            latitude: location.latitude, longitude: location.longitude) {
            settings.gridSquare = grid
        }

        do {
            let address = try await StationAddressResolver()
                .address(latitude: location.latitude, longitude: location.longitude)
            if !address.city.isEmpty { profile.city = address.city }
            if !address.state.isEmpty { profile.state = address.state }
            if !address.county.isEmpty { profile.county = address.county }
            if !address.postalCode.isEmpty { profile.postalCode = address.postalCode }
            if !address.street.isEmpty { profile.street = address.street }
            locationNote = "Grid square and address set from \(location.source.rawValue)."
        } catch {
            // The grid square still landed — say so, so this does not
            // read as a total failure.
            locationNote = "Grid square set to \(settings.gridSquare). "
                + (error.localizedDescription)
            locationNoteIsError = true
        }
    }
}

/// Live account of what sync last did.
///
/// Sync that shows only a switch is sync nobody trusts. When a message has
/// not turned up on the other device the operator needs to know whether the
/// last pass ran, what it moved, and why it stopped — so this states it
/// rather than implying it with a spinner.
private struct SyncStatusRow: View {

    @ObservedObject var sync: WinlinkSyncController

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(sync.status.summary)
                    .font(.caption)
                Text("This device: \(WinlinkSyncDevice.shortName(deviceID))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Identifies this installation when two devices both hold a queued message. Only the device holding the claim transmits it, so the same message cannot go out twice.")
            }
            Spacer(minLength: 0)
            Button("Sync Now") { sync.syncNow() }
                .controlSize(.small)
                .disabled(sync.status.isBusy)
        }
        .help(sync.status.detail)
    }

    @ViewBuilder
    private var icon: some View {
        switch sync.status {
        case .syncing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unavailable:
            Image(systemName: "icloud.slash").foregroundStyle(.secondary)
        default:
            Image(systemName: "icloud").foregroundStyle(.secondary)
        }
    }

    private var deviceID: String { WinlinkSyncDevice.identifier() }
}
