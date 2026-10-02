//
//  WinlinkPeerCallSheet.swift
//  AXTerm
//
//  Asks which station to call for a peer-to-peer exchange. See
//  WinlinkPeerCall for the callsign rules and the suggestion.
//

import SwiftUI

struct WinlinkPeerCallSheet: View {
    let myCallsign: String
    let recentPeers: [String]
    let onCall: (_ callsign: String, _ path: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var callsign: String
    @State private var path = ""

    init(myCallsign: String, suggestion: String, recentPeers: [String],
         onCall: @escaping (_ callsign: String, _ path: String) -> Void) {
        self.myCallsign = myCallsign
        self.recentPeers = recentPeers
        self.onCall = onCall
        _callsign = State(initialValue: suggestion)
    }

    private var peer: String? {
        WinlinkPeerCall.callsign(from: callsign, myCallsign: myCallsign)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Peer-to-Peer Exchange", systemImage: "arrow.left.arrow.right.circle")
                .font(.headline)
            Text("Calls another Winlink station directly and swaps mail with it. No gateway or internet is involved, so mail addressed to anyone else stays in your Outbox. The other station has to be listening for peer-to-peer calls.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Station", text: $callsign, prompt: Text("e.g. K0EPI-3"))
                    .textFieldStyle(.roundedBorder)
                    .help("The callsign the other station listens on, with its SSID.")
                if !recentPeers.isEmpty {
                    Menu("Recent") {
                        ForEach(recentPeers, id: \.self) { recent in
                            Button(recent) { callsign = recent }
                        }
                    }
                    .fixedSize()
                }
            }

            TextField("Via", text: $path, prompt: Text("Digipeaters, comma separated (optional)"))
                .textFieldStyle(.roundedBorder)
                .help("Leave empty to call the station directly.")

            if !callsign.trimmingCharacters(in: .whitespaces).isEmpty, peer == nil {
                Text(CallsignValidator.normalize(callsign) == CallsignValidator.normalize(myCallsign)
                     ? "That is your own callsign."
                     : "That doesn't look like a callsign.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Call") {
                    guard let peer else { return }
                    dismiss()
                    onCall(peer, path.trimmingCharacters(in: .whitespaces).uppercased())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(peer == nil)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
