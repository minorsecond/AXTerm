//
//  BBSTrustedCallersEditor.swift
//  AXTerm
//

import SwiftUI

/// The callers who may upload straight into an area that takes their
/// uploads (home retest 2026-10-10, finding 11). The operator's own
/// callsign is always on it.
struct BBSTrustedCallersEditor: View {
    @ObservedObject var settings: BBSSettings
    /// The mailbox's callsign, for the line that says the operator is trusted.
    let station: String

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(BBSTrust.summary(station: station, list: []) + ", at any SSID",
                          systemImage: "person.crop.circle.badge.checkmark")
                    ForEach(settings.trustedCallers, id: \.self) { call in
                        row(call)
                    }
                } footer: {
                    Text("These callers can upload straight into an area you have switched to take their "
                         + "uploads, by typing U and the area's name. A callsign without an SSID covers every "
                         + "SSID. Everyone else's uploads go to the inbox.")
                }
                Section {
                    HStack {
                        TextField("Callsign", text: $draft)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(BBSTrust.entry(from: draft) == nil)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Trusted Callers")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .modifier(PlatformSheetFrame(macWidth: 420, macHeight: 460))
    }

    @ViewBuilder
    private func row(_ call: String) -> some View {
        #if os(macOS)
        HStack {
            Text(call).font(.system(.body, design: .monospaced))
            Spacer()
            Button(role: .destructive) {
                remove(call)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop trusting \(call)")
            .accessibilityLabel("Remove \(call)")
        }
        #else
        Text(call).font(.system(.body, design: .monospaced))
            .swipeActions {
                Button("Remove", role: .destructive) { remove(call) }
            }
        #endif
    }

    private func add() {
        guard let entry = BBSTrust.entry(from: draft) else { return }
        if !settings.trustedCallers.contains(entry) { settings.trustedCallers.append(entry) }
        draft = ""
    }

    private func remove(_ call: String) {
        settings.trustedCallers.removeAll { $0 == call }
    }
}
