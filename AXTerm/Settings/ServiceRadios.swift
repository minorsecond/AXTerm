import SwiftUI

/// Which radios a station-wide service runs on, for the service pages.
///
/// The switches themselves are in each radio's section (`RadioRoleSections`).
/// A "Runs on" line only says where the service ends up running, so the one
/// fact has one control.
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
