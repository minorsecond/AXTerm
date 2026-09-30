import SwiftUI

/// What a radio does on the air, shown on the service page for its channel.
///
/// A radio's own page holds its hardware and identity. Its APRS path and
/// position beacon are under APRS, and its packet services, digipeater and
/// ID beacon under Packet Node, one radio to a section, so the operator sets
/// up a role beside the station-wide switches it depends on. The stored
/// settings are the radio's (`RadioProfile`) wherever they are shown.
nonisolated enum RadioRoleSections {

    /// The radios on `channel`, in list order. A radio switched off is
    /// listed too: its settings are still its own, and its page links here.
    static func radios(on channel: RadioChannel, in radios: [RadioProfile]) -> [RadioProfile] {
        radios.filter { !$0.archived && RadioChannel.of($0) == channel }
    }

    /// The id of a radio's first section on its channel's page.
    static func anchor(_ radio: RadioID, on channel: RadioChannel) -> String {
        "\(channel.rawValue).\(radio.rawValue)"
    }

    /// Where a link to a page's radio sections scrolls: the radio it names,
    /// else the first radio on the page, else the note that there is none.
    static func landing(for radio: RadioID?, among radios: [RadioProfile],
                        on channel: RadioChannel) -> AnyHashable {
        let ids = radios.map(\.id)
        if let radio, ids.contains(radio) { return AnyHashable(anchor(radio, on: channel)) }
        if let first = ids.first { return AnyHashable(anchor(first, on: channel)) }
        return AnyHashable(channel == .aprs ? SettingsSection.aprsRadios : .packetRadios)
    }

    /// A radio's section header: its name, the callsign it goes on the air
    /// with, and "off" when it is switched off.
    static func header(for radio: RadioProfile, callsign: String) -> String {
        var parts = [RadioDetailView.title(for: radio)]
        if !callsign.isEmpty { parts.append(callsign) }
        if !radio.enabled { parts.append("off") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// One line for the radio's page, saying what the service page holds
    /// for this radio.
    static func summary(for radio: RadioProfile) -> String {
        let beacon = radio.beacon
        let matches = RadioChannel.beaconMatchesChannel(radio)
        switch RadioChannel.of(radio) {
        case .aprs:
            let path = radio.effectiveAPRSPath.isEmpty ? "direct" : radio.effectiveAPRSPath
            let sends = !matches ? "Beacon set up for a packet channel"
                : beacon.enabled ? "Beacon every \(beacon.intervalMinutes) min" : "Beacon off"
            return "\(sends), path \(path)"
        case .packet:
            var on: [String] = []
            if radio.announcesNode { on.append("node") }
            if radio.pings { on.append("ping") }
            if radio.answersMailbox { on.append("mailbox") }
            if radio.digi.enabled { on.append("digipeater") }
            if matches, beacon.enabled { on.append("ID beacon every \(beacon.intervalMinutes) min") }
            var text = on.isEmpty ? "All off" : "On: " + on.joined(separator: ", ")
            if !matches { text += ". Beacon set up for an APRS channel" }
            return text
        }
    }
}

// MARK: - APRS

/// One APRS radio's section on the APRS page: its path, then its position
/// beacon.
struct RadioAPRSSections: View {
    let radioID: RadioID
    @ObservedObject var settings: AppSettingsStore
    /// Read for whether this radio's link is up, which "Send one now" needs.
    @ObservedObject var client: PacketEngine

    @State private var showingSymbolPicker = false

    private var profile: RadioProfile {
        settings.radio(radioID) ?? RadioProfile(id: radioID, name: "")
    }

    private var bind: RadioRoleBindings { RadioRoleBindings(radioID: radioID, settings: settings) }

    var body: some View {
        Section {
            RadioAPRSPathRow(path: bind.aprsPath)

            if RadioChannel.beaconMatchesChannel(profile) {
                Toggle("Send a position beacon", isOn: bind.beacon(\.enabled))
                if bind.beacon(\.enabled).wrappedValue {
                    positionBeaconRows
                    Stepper("Send every \(bind.beacon(\.intervalMinutes).wrappedValue) min",
                            value: bind.beacon(\.intervalMinutes), in: 5...240, step: 5)
                    RadioBeaconNowRow(radioID: radioID, settings: settings,
                                      linkUp: client.radioSummaries.first { $0.id == radioID }?.status == .connected)
                }
            } else {
                RadioMismatchedBeaconRows(profile: profile, channel: .aprs, bind: bind)
            }
        } header: {
            Text(RadioRoleSections.header(for: profile, callsign: settings.onAirCallsign(for: radioID)))
        } footer: {
            Text("The path is for everything APRS this radio sends: the beacon, the map's Ping and "
                 + "your messages. The beacon uses the station position from General unless this "
                 + "radio has a fixed one.")
        }
        .id(RadioRoleSections.anchor(radioID, on: .aprs))
    }

    @ViewBuilder
    private var positionBeaconRows: some View {
        let symbol = currentSymbol
        LabeledContent("Symbol") {
            HStack(spacing: 8) {
                Text("\(String(symbol.table))\(String(symbol.code))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(symbol.label).lineLimit(1)
                Spacer()
                Button("Choose\u{2026}") { showingSymbolPicker = true }
            }
        }
        // On the row rather than the page: a page holds one sheet per view,
        // and the APRS page has a section like this for every APRS radio.
        .sheet(isPresented: $showingSymbolPicker) {
            APRSSymbolPicker(
                selectedTable: currentSymbol.table,
                selectedCode: currentSymbol.code) { table, code in
                    settings.updateRadio(radioID) {
                        if $0.beacon.aprs == nil { $0.beacon.aprs = .followingStation }
                        $0.beacon.aprs?.symbolTable = String(table)
                        $0.beacon.aprs?.symbolCode = String(code)
                    }
                    bind.apply()
                }
        }

        if (profile.beacon.aprs?.symbolTable ?? "/") != "/" {
            LabeledContent("Overlay") {
                TextField("Overlay", text: bind.overlay, prompt: Text("none"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 60)
                    .help("A single 0\u{2013}9 or A\u{2013}Z drawn over an alternate-table symbol "
                          + "(an S over the digi star, say). Leave empty for the plain "
                          + "alternate symbol.")
            }
        }

        TextField("Comment (optional)", text: bind.aprs(\.comment, default: ""))
            .textFieldStyle(.roundedBorder)

        Picker("Position", selection: bind.aprs(\.useGPS, default: true)) {
            Text("Station position").tag(true)
            Text("Fixed position for this radio").tag(false)
        }
        .help("Station position is the one under General \u{203A} Station position, the same one "
              + "the map uses: the exact coordinate when one is set, else this device's location "
              + "when that is switched on, else the center of the grid square. A fixed position "
              + "suits a radio that stays put while the station moves.")
        if bind.aprs(\.useGPS, default: true).wrappedValue {
            Text(stationPositionLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LabeledContent("Latitude") {
                TextField("Latitude", text: bind.coordString(\.latitude), prompt: Text("39.5000"))
                    .labelsHidden()
                    .coordinateEntry()
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
            }
            LabeledContent("Longitude") {
                TextField("Longitude", text: bind.coordString(\.longitude), prompt: Text("-105.2500"))
                    .labelsHidden()
                    .coordinateEntry()
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
            }
        }

        Stepper("Position ambiguity: \(bind.aprs(\.ambiguityDigits, default: 0).wrappedValue)",
                value: bind.aprs(\.ambiguityDigits, default: 0), in: 0...4)
            .help("Blanks this many low-order digits of the minutes, so the beacon places you "
                  + "less exactly. 0 sends the position as it is; each step is roughly ten "
                  + "times coarser, and 4 leaves about a degree.")
        Toggle("Compressed position", isOn: bind.aprs(\.compressed, default: false))
            .help("The base-91 form: a shorter frame, less airtime, and more precision than "
                  + "the plain form. Older receivers show the plain form more readably.")

        if let example = aprsExample {
            Text(example)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// Where a beacon that follows the station would put it right now.
    private var stationPositionLine: String {
        guard let position = SessionCoordinator.shared?.aprsLocationProvider?() else {
            return "No station position yet. Set one under General \u{203A} Station position."
        }
        return String(format: "Now: %.4f, %.4f", position.latitude, position.longitude)
    }

    /// The symbol the beacon currently uses, resolved to its catalog label.
    private var currentSymbol: APRSSymbol {
        let aprs = profile.beacon.aprs
        let table = aprs?.symbolTable.first ?? "/"
        let code = aprs?.symbolCode.first ?? "-"
        return APRSSymbolCatalog.symbol(table: table, code: code)
            ?? APRSSymbol(table: table, code: code, label: "Custom")
    }

    /// The exact info field this beacon would send, for the operator to see
    /// before it goes out. Nil when there is no position to show.
    private var aprsExample: String? {
        let aprs = profile.beacon.aprs ?? .followingStation
        let coordinate: (latitude: Double, longitude: Double)?
        if aprs.useGPS {
            coordinate = SessionCoordinator.shared?.aprsLocationProvider?()
        } else if let lat = aprs.latitude, let lon = aprs.longitude {
            coordinate = (lat, lon)
        } else {
            coordinate = nil
        }
        guard let coordinate else { return nil }
        let report = APRSBeacon.PositionReport(
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            symbolTable: aprs.symbolTable.first ?? "/",
            symbolCode: aprs.symbolCode.first ?? "-",
            ambiguity: aprs.ambiguityDigits, comment: aprs.comment, compressed: aprs.compressed)
        return APRSBeacon.infoField(report)
    }
}

// MARK: - Packet

/// One packet radio's sections on the Packet Node page: which services use
/// it, its digipeater and its ID beacon.
struct RadioPacketSections: View {
    let radioID: RadioID
    @ObservedObject var settings: AppSettingsStore
    /// Read for whether this radio's link is up, which "Send one now" needs.
    @ObservedObject var client: PacketEngine

    private var profile: RadioProfile {
        settings.radio(radioID) ?? RadioProfile(id: radioID, name: "")
    }

    private var title: String { RadioDetailView.title(for: profile) }

    private var bind: RadioRoleBindings { RadioRoleBindings(radioID: radioID, settings: settings) }

    var body: some View {
        servicesSection
        digipeaterSection
        beaconSection
    }

    private var servicesSection: some View {
        Section {
            Toggle("Announce the NET/ROM node", isOn: bind.service(\.announcesNode))
                .help("Carry the node's NODES broadcast on this radio, under this radio's "
                      + "callsign, when the node announces itself (NET/ROM Node, above).")
            if settings.netRomNodeIdentity == .perRadio,
               bind.service(\.announcesNode).wrappedValue {
                LabeledContent("Node alias on this radio") {
                    TextField("Node alias on this radio", text: bind.netRomAlias,
                              prompt: Text(settings.netRomNodeAlias.isEmpty ? "e.g. UHFNOD" : settings.netRomNodeAlias))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                }
                .help("The six-character name this radio's node announces under, because "
                      + "each radio is its own node (Node identity, above). "
                      + "Empty uses the station alias, which two nodes cannot share.")
            }
            Toggle("Ping stations", isOn: bind.service(\.pings))
                .help("Ask stations this radio heard whether they can hear it back. A radio "
                      + "switched off here asks nobody. Pacing is the station's (Ping, below).")
            Toggle("Answer mailbox calls", isOn: bind.service(\.answersMailbox))
                .help("Let the mailbox answer calls that arrive on this radio. Whether the "
                      + "mailbox is on the air at all is set under BBS.")
        } header: {
            Text(RadioRoleSections.header(for: profile, callsign: settings.onAirCallsign(for: radioID)))
        } footer: {
            Text(RadioServiceNotes.packetFooter(radio: profile, settings: settings))
        }
        .id(RadioRoleSections.anchor(radioID, on: .packet))
    }

    private var digipeaterSection: some View {
        Section {
            Toggle("Digipeat on this radio", isOn: bind.digi(\.enabled))
                .help("Retransmit frames whose via path names this station or an alias below, "
                      + "or a WIDEn-N this digipeater honors. Off by default: it volunteers "
                      + "your transmitter for other people's traffic.")
            if bind.digi(\.enabled).wrappedValue {
                Toggle("Fill-in (WIDE1-1)", isOn: bind.digi(\.fillIn))
                    .help("Repeat the first WIDE1-1 hop, as a home fill-in digipeater does.")
                Stepper(bind.digi(\.wideAreaMaxHops).wrappedValue == 0
                        ? "Wide-area: off"
                        : "Wide-area hops: \(bind.digi(\.wideAreaMaxHops).wrappedValue)",
                        value: bind.digi(\.wideAreaMaxHops), in: 0...7)
                    .help("The largest WIDEn-N this digipeater still repeats. 0 turns wide-area "
                          + "repeating off; 2 is a responsible default that does not "
                          + "regenerate WIDE7-7 floods.")
                LabeledContent("Also answer to") {
                    TextField("Also answer to", text: bind.digiAliases,
                              prompt: Text("aliases (comma-separated)"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                }
                .help("Other names this digipeater repeats for, such as a club alias. Its "
                      + "own callsign is always included.")
                Stepper("Dupe window: \(bind.digi(\.dupeSeconds).wrappedValue) s",
                        value: bind.digi(\.dupeSeconds), in: 5...120, step: 5)
                    .help("A frame heard again within this many seconds is not repeated, so "
                          + "the digipeater never loops or echoes.")
            }
        } header: {
            Text("\(title) digipeater")
        } footer: {
            Text("Repeats other stations' traffic on this radio's channel only.")
        }
    }

    private var beaconSection: some View {
        Section {
            if RadioChannel.beaconMatchesChannel(profile) {
                Toggle("Send an ID beacon", isOn: bind.beacon(\.enabled))
                if bind.beacon(\.enabled).wrappedValue {
                    idBeaconRows
                    Stepper("Send every \(bind.beacon(\.intervalMinutes).wrappedValue) min",
                            value: bind.beacon(\.intervalMinutes), in: 5...240, step: 5)
                    RadioBeaconNowRow(radioID: radioID, settings: settings,
                                      linkUp: client.radioSummaries.first { $0.id == radioID }?.status == .connected)
                }
            } else {
                RadioMismatchedBeaconRows(profile: profile, channel: .packet, bind: bind)
            }
        } header: {
            Text("\(title) ID beacon")
        } footer: {
            Text("Plain text sent to BEACON on a timer, the way nodes on a packet channel "
                 + "say who they are. A radio does not beacon until you switch it on here.")
        }
    }

    @ViewBuilder
    private var idBeaconRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Beacon text", text: bind.beacon(\.text), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Text("\(bind.beacon(\.text).wrappedValue.utf8.count) of "
                 + "\(BeaconPlan.maxTextBytes) bytes \u{b7} sent to BEACON")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if case let .failure(problem) = BeaconPlan.plan(
                text: bind.beacon(\.text).wrappedValue,
                path: bind.beacon(\.path).wrappedValue) {
                Text(problem.operatorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        LabeledContent("Via digipeaters") {
            TextField("Via digipeaters", text: bind.beacon(\.path), prompt: Text("direct"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
        }
        .help("Up to two digipeaters, comma-separated. Empty sends it direct, heard only "
              + "by stations in range of this radio.")
    }
}

// MARK: - Shared rows

/// A beacon stored before channels were one or the other, whose kind is
/// not this channel's. Said plainly, with the one change that fixes it,
/// rather than showing controls for a beacon this radio does not send.
private struct RadioMismatchedBeaconRows: View {
    let profile: RadioProfile
    let channel: RadioChannel
    let bind: RadioRoleBindings

    var body: some View {
        let beacon = profile.beacon
        let sends = beacon.kind == .aprsPosition ? "an APRS position beacon" : "a text ID beacon"
        Text(beacon.enabled
             ? "This radio sends \(sends) every \(beacon.intervalMinutes) min, which is not the "
                + "kind a \(channel.title) channel uses."
             : "This radio's beacon is set up as \(sends), which is not the kind a "
                + "\(channel.title) channel uses. It is switched off.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        Button(channel == .aprs ? "Use a position beacon" : "Use an ID beacon") {
            bind.settings.updateRadio(bind.radioID) { channel.apply(to: &$0) }
            bind.apply()
        }
    }
}

/// Beacon this radio now, and say why not when it cannot.
///
/// The interval is a floor of five minutes and usually half an hour, so
/// without this the only way to see whether a beacon works was to wait for
/// it.
private struct RadioBeaconNowRow: View {
    let radioID: RadioID
    let settings: AppSettingsStore
    let linkUp: Bool

    /// What the last "Send one now" did, shown under the button for a while.
    @State private var beaconNowResult: BeaconNowFeedback.Result?

    var body: some View {
        let obstacle = BeaconNowFeedback.blocker(
            obstacle: SessionCoordinator.shared?.beaconObstacle(for: radioID, settings: settings),
            linkUp: linkUp)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Send one now") {
                    guard let coordinator = SessionCoordinator.shared else {
                        beaconNowResult = .failed("AXTerm isn't ready to transmit yet.")
                        return
                    }
                    if let why = coordinator.sendBeacon(for: radioID, settings: settings) {
                        beaconNowResult = .failed(why)
                    } else {
                        beaconNowResult = .sent(Date())
                    }
                }
                .disabled(obstacle != nil)
                Text(obstacle == nil
                     ? "Goes out on this radio immediately."
                     : "Cannot send yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let obstacle {
                Text(obstacle)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let result = beaconNowResult {
                switch result {
                case .sent(let at):
                    Label(BeaconNowFeedback.sentLine(at: at), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let why):
                    Label("Not sent: \(why)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // The confirmation is for the moment after the click, not a record.
        .task(id: beaconNowResult) {
            guard beaconNowResult != nil else { return }
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { beaconNowResult = nil }
        }
    }
}

/// Bindings to one radio's role settings. Every write re-applies the node
/// settings, so a new path, beacon, service switch or digipeater setting
/// takes effect at once rather than at relaunch.
@MainActor
struct RadioRoleBindings {
    let radioID: RadioID
    let settings: AppSettingsStore

    func apply() {
        SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
    }

    /// This radio's APRS path, resolving an older build's beacon path on
    /// first read so an upgrade never silently shortens a station's reach.
    var aprsPath: Binding<String> {
        Binding(
            get: { settings.radio(radioID)?.effectiveAPRSPath ?? "" },
            set: { value in
                settings.updateRadio(radioID) { $0.aprsPath = value.uppercased() }
                apply()
            })
    }

    /// Bind one field of this radio's beacon.
    func beacon<V>(_ keyPath: WritableKeyPath<BeaconConfig, V>) -> Binding<V> {
        Binding(
            get: { (settings.radio(radioID)?.beacon ?? BeaconConfig())[keyPath: keyPath] },
            set: { value in
                settings.updateRadio(radioID) { $0.beacon[keyPath: keyPath] = value }
                apply()
            })
    }

    /// Bind one field of this radio's APRS position config, creating it on
    /// first write. A new config follows the station position.
    func aprs<V>(_ keyPath: WritableKeyPath<APRSPositionConfig, V>, default def: V) -> Binding<V> {
        Binding(
            get: { settings.radio(radioID)?.beacon.aprs?[keyPath: keyPath] ?? def },
            set: { value in
                settings.updateRadio(radioID) {
                    if $0.beacon.aprs == nil { $0.beacon.aprs = .followingStation }
                    $0.beacon.aprs?[keyPath: keyPath] = value
                }
                apply()
            })
    }

    /// The overlay character (the symbol table byte when it is not `/` or
    /// `\`). Setting it makes the symbol an overlay of the alternate table;
    /// clearing it returns to the plain alternate table.
    var overlay: Binding<String> {
        Binding(
            get: {
                let t = settings.radio(radioID)?.beacon.aprs?.symbolTable ?? "/"
                return (t == "/" || t == "\\") ? "" : t
            },
            set: { str in
                let ch = str.uppercased().first
                settings.updateRadio(radioID) {
                    if $0.beacon.aprs == nil { $0.beacon.aprs = .followingStation }
                    if let ch, ch != "/", ch != "\\" {
                        $0.beacon.aprs?.symbolTable = String(ch)
                    } else {
                        // Cleared: overlays live on the alternate table.
                        $0.beacon.aprs?.symbolTable = "\\"
                    }
                }
                apply()
            })
    }

    /// A text binding for an optional coordinate field.
    func coordString(_ keyPath: WritableKeyPath<APRSPositionConfig, Double?>) -> Binding<String> {
        Binding(
            get: {
                if let v = settings.radio(radioID)?.beacon.aprs?[keyPath: keyPath] {
                    return String(v)
                }
                return ""
            },
            set: { str in
                let value = Double(str.trimmingCharacters(in: .whitespaces))
                settings.updateRadio(radioID) {
                    if $0.beacon.aprs == nil { $0.beacon.aprs = .followingStation }
                    $0.beacon.aprs?[keyPath: keyPath] = value
                }
                apply()
            })
    }

    func service(_ keyPath: WritableKeyPath<RadioProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.radio(radioID)?[keyPath: keyPath] ?? true },
            set: { value in
                settings.updateRadio(radioID) { $0[keyPath: keyPath] = value }
                // The node's L2 aliases are registered when configured, not
                // when announced.
                apply()
            })
    }

    /// This radio's NET/ROM node alias (used when the node identity is
    /// per-radio). Empty means the station alias.
    var netRomAlias: Binding<String> {
        Binding(
            get: { settings.radio(radioID)?.netRomAlias ?? "" },
            set: { value in
                settings.updateRadio(radioID) { $0.netRomAlias = value.uppercased() }
                apply()
            })
    }

    /// Bind one field of this radio's digipeater config.
    func digi<V>(_ keyPath: WritableKeyPath<DigiConfig, V>) -> Binding<V> {
        Binding(
            get: { (settings.radio(radioID)?.digi ?? DigiConfig())[keyPath: keyPath] },
            set: { value in
                settings.updateRadio(radioID) { $0.digi[keyPath: keyPath] = value }
                apply()
            })
    }

    /// This radio's digi aliases as one comma-separated field.
    var digiAliases: Binding<String> {
        Binding(
            get: { (settings.radio(radioID)?.digi.aliases ?? []).joined(separator: ", ") },
            set: { text in
                let aliases = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                    .map { $0.uppercased() }
                settings.updateRadio(radioID) { $0.digi.aliases = aliases }
                apply()
            })
    }
}

// MARK: - The path row and the wording

/// The APRS path field, its presets, and what the path costs.
///
/// Presets rather than a bare field because the two paths worth using are
/// conventions, not preferences; typing is still allowed, because a local
/// network with a named digipeater is a real answer the presets cannot know.
struct RadioAPRSPathRow: View {
    @Binding var path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Path") {
                HStack(spacing: 8) {
                    // Labels hidden: in a grouped form a text field's title
                    // shows as a second label, and "direct" sat beside a
                    // field that said WIDE1-1,WIDE2-1.
                    TextField("Path", text: $path, prompt: Text("direct"))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                    // Labeled with the path in the field, or Custom, so the
                    // menu never names a different path from the one used.
                    Menu {
                        ForEach(APRSPath.presets, id: \.self) { preset in
                            Button(APRSPath.label(preset)) { path = preset }
                        }
                    } label: {
                        Text(APRSPath.menuTitle(path))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Common paths.")
                }
            }
            if case let .failure(problem) = BeaconPlan.planPath(path) {
                Text(problem.operatorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Self.explanation(path))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let advice = APRSPath.advice(path) {
                    Text(advice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What a path costs and what it buys, in the operator's terms.
    static func explanation(_ path: String) -> String {
        let total = APRSPath.transmissions(path)
        if total == 1 {
            return "Direct only: heard by stations in range of this radio, and no further. "
                + "Nothing on APRS is repeated unless the frame asks."
        }
        return "Asks for \(total - 1) digipeater hop\(total - 1 == 1 ? "" : "s"): "
            + "\(total) transmissions of every frame."
    }
}

/// What the beacon's "Send one now" button says about itself. Pure, so the
/// wording can be tested.
nonisolated enum BeaconNowFeedback {
    enum Result: Equatable {
        case sent(Date)
        case failed(String)
    }

    /// Why the button can't send: the beacon's own problem first (it needs
    /// fixing whatever the link does), then a radio that isn't connected.
    static func blocker(obstacle: String?, linkUp: Bool) -> String? {
        if let obstacle { return obstacle }
        return linkUp ? nil : "This radio isn't connected. Connect it on its page under Radios, then send."
    }

    /// The confirmation, with the time the frame went to the radio.
    static func sentLine(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return "Sent at \(formatter.string(from: date))"
    }
}

/// The lines under a radio's packet services, saying what the station-wide
/// switches mean for them. Pure, so the wording can be tested.
nonisolated enum RadioServiceNotes {
    @MainActor
    static func packetFooter(radio: RadioProfile, settings: AppSettingsStore) -> String {
        packetFooter(radio: radio,
                     advertises: settings.netRomAdvertiseSelf,
                     pingEnabled: settings.pingEnabled)
    }

    static func packetFooter(radio: RadioProfile, advertises: Bool, pingEnabled: Bool) -> String {
        var off: [String] = []
        if radio.announcesNode, !advertises { off.append("the node does not announce itself") }
        if radio.pings, !pingEnabled { off.append("automatic ping is off") }
        var text = "These say which services use this radio."
        if !off.isEmpty {
            text += " For the station as a whole, " + off.joined(separator: " and ")
                + ", so switching them on here does nothing until that changes in the NET/ROM "
                + "Node and Ping sections on this page."
        }
        return text
    }
}
