import SwiftUI

/// Which radios a station-wide service runs on, for the service pages.
///
/// On the Packet Node page the switches are in each service's card
/// (`CarriedOnRow`). Elsewhere a "Runs on" line only says where the service
/// ends up running, so the one fact has one control.
nonisolated enum ServiceRadios {

    /// The names of the enabled radios `runs` accepts, in list order.
    static func names(_ radios: [RadioProfile], _ runs: (RadioProfile) -> Bool) -> [String] {
        radios
            .filter { !$0.archived && $0.enabled && runs($0) }
            .map { RadioDetailView.title(for: $0) }
    }

    /// The radios APRS messages may go out on (`RadioChannel.aprsRadios`).
    static func aprs(_ radios: [RadioProfile]) -> [String] {
        let carrying = Set(RadioChannel.aprsRadios(in: radios).map(\.id))
        return names(radios) { carrying.contains($0.id) }
    }

    /// The radios the mailbox answers calls on.
    static func mailbox(_ radios: [RadioProfile]) -> [String] {
        names(radios) { $0.mayAnswerMailbox }
    }

    /// The radios inbound Winlink calls can be answered on: every packet
    /// radio. A call arriving on an APRS channel is refused at the link
    /// (`AX25SessionManager.refusesInboundLinks`).
    static func winlinkPeerToPeer(_ radios: [RadioProfile]) -> [String] {
        names(radios) { $0.runsPacketServices }
    }
}

/// "Runs on: Base, IC-705", read-only.
struct RunsOnRow: View {
    let names: [String]
    /// What to say when no radio qualifies.
    let none: String

    var body: some View {
        if names.isEmpty {
            LabeledContent("Runs on") {
                Text("No radio").foregroundStyle(.secondary)
            }
            Text(none)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LabeledContent("Runs on") {
                Text(names.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// Which node several radios make: one, or one each. Only shown with
/// several radios, because with one the question has no content. A radio's
/// own alias, when each radio is its own node, is set in its section below.
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

            Text(settings.netRomNodeIdentity == .perRadio
                 ? settings.netRomNodeIdentity.explanation
                    + " Each radio's alias is set in its section below."
                 : settings.netRomNodeIdentity.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Carried on: IC-705  ID-50" with a switch per radio: where a service
/// runs, chosen in the service's own card on the Packet Node page (park
/// rehearsal 2026-10-08, finding 46). One radio needs no choice and shows
/// as text.
struct CarriedOnRow: View {
    @ObservedObject var settings: AppSettingsStore
    /// The radios that can carry it: packet radios that are switched on.
    let radios: [RadioProfile]
    let service: WritableKeyPath<RadioProfile, Bool>
    /// What to say when none carries it.
    let none: String

    var body: some View {
        LabeledContent("Carried on") {
            HStack(spacing: 6) {
                if radios.isEmpty {
                    Text("No radio is switched on").foregroundStyle(.secondary)
                }
                ForEach(radios) { radio in
                    Toggle(RadioDetailView.title(for: radio),
                           isOn: RadioRoleBindings(radioID: radio.id, settings: settings).service(service))
                        .toggleStyle(.button)
                }
            }
        }
        if !radios.isEmpty, !radios.contains(where: { settings.radio($0.id)?[keyPath: service] ?? false }) {
            Text(none)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
