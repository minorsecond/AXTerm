//
//  APRSSettingsView.swift
//  AXTerm
//
//  Services › APRS: messaging for the station as a whole, then a section
//  for each radio on an APRS channel with its path and position beacon.
//  Whether a radio is on an APRS channel is set on its page under Radios.
//

import SwiftUI

struct APRSSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    let client: PacketEngine
    @EnvironmentObject private var router: SettingsRouter

    var body: some View {
        SettingsForm(landing: [.aprsMessaging],
                     radios: RadioLanding(section: .aprsRadios) { radio in
                         RadioRoleSections.landing(for: radio, among: aprsRadios, on: .aprs)
                     }) {
            Section {
                RunsOnRow(names: ServiceRadios.aprs(settings.activeRadios),
                          none: "No radio is on an APRS channel, so no APRS goes out. Set a radio's channel to APRS on its page under Radios.")
                    .help("Where APRS messages, their acknowledgments and the \u{201C}who can "
                          + "hear me\u{201D} query go out: the radios whose channel is APRS, or "
                          + "your one radio when you have only one.")
                Picker("Auto-reply", selection: Binding(
                    get: { APRSMessagingService.AutoReply(rawValue: settings.aprsAutoReplyRaw) ?? .full },
                    set: { settings.aprsAutoReplyRaw = $0.rawValue })) {
                    Text("Full: ACK and answer queries").tag(APRSMessagingService.AutoReply.full)
                    Text("ACK only").tag(APRSMessagingService.AutoReply.ackOnly)
                    Text("Manual: never transmit on its own").tag(APRSMessagingService.AutoReply.manual)
                }
            } header: {
                Text("Messaging")
            } footer: {
                Text("What AXTerm transmits on its own, under your callsign, when an APRS message "
                     + "or directed query addressed to you arrives. Full acknowledges messages and "
                     + "answers ?APRSP, ?VER and ?APRSD; Manual sends nothing until you do.")
            }
            .id(SettingsSection.aprsMessaging)

            if aprsRadios.isEmpty {
                Section {
                    Text("No radio is on an APRS channel. A radio's path and position beacon "
                         + "appear here once its channel is APRS.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Radios\u{2026}") { router.navigate(to: .radios) }
                }
                .id(SettingsSection.aprsRadios)
            } else {
                ForEach(aprsRadios) { radio in
                    RadioAPRSSections(radioID: radio.id, settings: settings, client: client)
                }
            }
        }
    }

    private var aprsRadios: [RadioProfile] {
        RadioRoleSections.radios(on: .aprs, in: settings.activeRadios)
    }
}
