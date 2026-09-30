//
//  APRSSettingsView.swift
//  AXTerm
//
//  Services › APRS: what the station does with APRS as a whole. Whether a
//  radio is on an APRS channel, its path and its position beacon are that
//  radio's, and are set on its page under Radios.
//

import SwiftUI

struct APRSSettingsView: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        SettingsForm(landing: [.aprsMessaging]) {
            Section {
                RunsOnRow(names: ServiceRadios.aprs(settings.activeRadios),
                          none: "No radio is on an APRS channel, so no APRS goes out. Set a radio's channel to APRS on its page under Radios.")
                    .help("Where APRS messages, their acknowledgements and the \u{201C}who can "
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
        }
    }
}
