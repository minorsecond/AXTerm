import SwiftUI

/// One toggle per radio for a station-wide service — "Send on IC-705",
/// "Ping on Base" — shown only when there are radios to choose between.
///
/// The switch lives on the radio profile, so this view and the radio's own
/// page are two views of one fact.
struct RadioServiceRows: View {
    @ObservedObject var settings: AppSettingsStore
    /// "Send on", "Ping on", "Announce on".
    let verb: String
    let keyPath: WritableKeyPath<RadioProfile, Bool>
    let help: String
    /// Runs after a switch changes, for services that register state when
    /// they are configured rather than when they transmit.
    var onChange: (() -> Void)? = nil

    var body: some View {
        if settings.hasMultipleRadios {
            ForEach(settings.activeRadios) { radio in
                Toggle("\(verb) \(radio.name.isEmpty ? RadioProfile.defaultName(for: radio) : radio.name)",
                       isOn: binding(for: radio.id))
                    .disabled(!radio.enabled)
                    .help(radio.enabled ? help : "This radio is switched off.")
            }
        }
    }

    private func binding(for id: RadioID) -> Binding<Bool> {
        Binding(
            get: { settings.radio(id)?[keyPath: keyPath] ?? true },
            set: { value in
                settings.updateRadio(id) { $0[keyPath: keyPath] = value }
                onChange?()
            })
    }
}

/// Which node several radios make: one, or one each. Only shown with
/// several radios, because with one the question has no content.
struct NetRomNodeIdentityRows: View {
    @ObservedObject var settings: AppSettingsStore
    var onChange: (() -> Void)? = nil

    var body: some View {
        if settings.hasMultipleRadios {
            Picker("Node identity", selection: $settings.netRomNodeIdentity) {
                ForEach(NetRomNodeIdentity.allCases, id: \.self) { identity in
                    Text(identity.title).tag(identity)
                }
            }
            .onChange(of: settings.netRomNodeIdentity) { _, _ in onChange?() }
            .help(settings.netRomNodeIdentity.explanation)

            Text(settings.netRomNodeIdentity.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.netRomNodeIdentity == .perRadio {
                ForEach(settings.activeRadios) { radio in
                    LabeledContent("\(radio.name.isEmpty ? RadioProfile.defaultName(for: radio) : radio.name) alias") {
                        TextField(settings.netRomNodeAlias.isEmpty ? "e.g. UHFNOD" : settings.netRomNodeAlias,
                                  text: aliasBinding(for: radio.id))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                            .onSubmit { onChange?() }
                    }
                    .help("The six-character name this radio's node announces under. "
                          + "Empty uses the station alias — which two nodes cannot share.")
                }
            }
        }
    }

    private func aliasBinding(for id: RadioID) -> Binding<String> {
        Binding(
            get: { settings.radio(id)?.netRomAlias ?? "" },
            set: { value in settings.updateRadio(id) { $0.netRomAlias = value } })
    }
}
