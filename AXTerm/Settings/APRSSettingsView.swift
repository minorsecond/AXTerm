//
//  APRSSettingsView.swift
//  AXTerm
//
//  Services → APRS: which radios are on an APRS channel, their paths, how
//  AXTerm answers APRS messages, and where each radio's position beacon is.
//

import SwiftUI

struct APRSSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @EnvironmentObject private var router: SettingsRouter

    var body: some View {
        Form {
            Section {
                ForEach(settings.activeRadios) { radio in
                    Toggle(settings.hasMultipleRadios ? "APRS on \(Self.name(radio))" : "This radio is on an APRS channel",
                           isOn: aprsBinding(radio.id))
                        .help("APRS messages and the \u{201C}Who can hear me\u{201D} query may go out on this radio. Leave off for a node or BBS frequency.")
                    if settings.radio(radio.id)?.aprsEnabled == true {
                        pathRow(radio.id)
                    }
                }
            } header: {
                Text("Channels")
            } footer: {
                Text("APRS only goes out on radios switched on here, so a node frequency is never flooded with an APRS query. On an APRS channel the packet services (node announcements, the mailbox, pings and AXDP probes) stay off for that radio: a shared beacon channel is no place for them. Their settings are kept and come back if you switch APRS off.")
            }

            Section {
                Picker("Auto-reply", selection: Binding(
                    get: { APRSMessagingService.AutoReply(rawValue: settings.aprsAutoReplyRaw) ?? .full },
                    set: { settings.aprsAutoReplyRaw = $0.rawValue })) {
                    Text("Full — ACK + answer queries").tag(APRSMessagingService.AutoReply.full)
                    Text("ACK only").tag(APRSMessagingService.AutoReply.ackOnly)
                    Text("Manual — never auto-transmit").tag(APRSMessagingService.AutoReply.manual)
                }
            } header: {
                Text("Messaging")
            } footer: {
                Text("What AXTerm transmits on its own, under your callsign, when an APRS message or directed query addressed to you arrives. Full auto-ACKs messages and answers ?APRSP, ?VER and ?APRSD; Manual sends nothing until you do.")
            }

            Section {
                ForEach(settings.activeRadios) { radio in
                    LabeledContent(settings.hasMultipleRadios ? Self.name(radio) : "Beacon") {
                        HStack {
                            Text(Self.beaconSummary(radio))
                                .foregroundStyle(.secondary)
                            Button("Edit\u{2026}") { router.navigate(to: .radios, radio: radio.id) }
                        }
                    }
                }
            } header: {
                Text("Position beacon")
            } footer: {
                Text("Each radio sends its own beacon, so its symbol, position, comment and interval are set on the radio's own page. Choosing an APRS position beacon there switches APRS on for that radio.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Rows

    private func pathRow(_ id: RadioID) -> some View {
        LabeledContent(settings.hasMultipleRadios ? "Path" : "APRS path") {
            HStack(spacing: 8) {
                TextField("direct", text: Binding(
                    get: { settings.radio(id)?.effectiveAPRSPath ?? "" },
                    set: { setPath($0, for: id) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                Menu {
                    ForEach(APRSPath.presets, id: \.self) { preset in
                        Button(APRSPath.label(preset)) { setPath(preset, for: id) }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help("Common paths.")
            }
        }
    }

    private func aprsBinding(_ id: RadioID) -> Binding<Bool> {
        Binding(
            get: { settings.radio(id)?.aprsEnabled ?? false },
            set: { value in
                settings.updateRadio(id) { $0.aprsEnabled = value }
                SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
            })
    }

    private func setPath(_ path: String, for id: RadioID) {
        settings.updateRadio(id) { $0.aprsPath = path.uppercased() }
        SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
    }

    // MARK: Text

    static func name(_ radio: RadioProfile) -> String {
        radio.name.isEmpty ? RadioProfile.defaultName(for: radio) : radio.name
    }

    static func beaconSummary(_ radio: RadioProfile) -> String {
        let beacon = radio.beacon
        guard beacon.enabled else { return "Off" }
        guard beacon.kind == .aprsPosition else { return "Text, every \(beacon.intervalMinutes) min" }
        let symbol = beacon.aprs.map { "symbol \($0.symbolTable)\($0.symbolCode)" } ?? "default symbol"
        return "Position, \(symbol), every \(beacon.intervalMinutes) min"
    }
}
