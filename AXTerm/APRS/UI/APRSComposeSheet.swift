import SwiftUI

/// Composing an APRS message.
///
/// Laid out by hand rather than with `Form`. A `Form` on macOS puts every
/// field's placeholder into a leading label column, so "Callsign (e.g.
/// W0ARP-9)" was rendered as a label beside an empty box while the section
/// headers "To" and "Message" floated above unrelated rows. The result read as
/// three labels for two fields (2026-09-17).
///
/// The additions are all the same idea: an APRS message is one shot at 67
/// characters with no delivery guarantee, so everything that decides whether
/// it will arrive should be visible before it goes, not discovered afterwards.
struct APRSComposeSheet: View {
    var myCallsign: String
    var initialTo: String = ""
    /// Stations heard here, offered as addressees and used to say whether the
    /// one typed has actually been heard.
    var heardStations: [APRSComposeModel.Suggestion] = []
    var onSend: (_ to: String, _ text: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: APRSComposeModel
    @FocusState private var focus: Field?

    private enum Field: Hashable { case to, text }

    init(myCallsign: String,
         initialTo: String = "",
         heardStations: [APRSComposeModel.Suggestion] = [],
         onSend: @escaping (_ to: String, _ text: String) -> Void) {
        self.myCallsign = myCallsign
        self.initialTo = initialTo
        self.heardStations = heardStations
        self.onSend = onSend
        _model = State(initialValue: APRSComposeModel(to: initialTo))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    addressee
                    message
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 380)
        .onAppear { focus = model.normalizedTo.isEmpty ? .to : .text }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("New APRS Message").font(.headline)
            // Which of the operator's addresses it leaves as. A station with a
            // node, a BBS and a tracker has several, and the reply comes back
            // to whichever one sent it.
            Text("From \(myCallsign.isEmpty ? "this station" : myCallsign.uppercased())")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    // MARK: - Addressee

    private var addressee: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To").font(.subheadline.weight(.medium))

            HStack(spacing: 8) {
                TextField("W0ARP-9", text: $model.to)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($focus, equals: .to)
                    .callsignInput()
                    .onSubmit { focus = .text }

                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions) { station in
                            Button {
                                model.to = station.callsign
                                focus = .text
                            } label: {
                                Text(station.callsign + (station.via.map { " via \($0)" } ?? ""))
                            }
                        }
                    } label: {
                        Label("Heard", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Stations heard here, most recent first.")
                }
            }

            if let problem = model.addresseeProblem {
                note(problem, symbol: "exclamationmark.triangle.fill", tint: .orange)
            } else if let match = model.match(in: heardStations) {
                // Confirms a prefilled addressee back. Opened from a station's
                // card the field arrives filled in, which looks identical to
                // one that was typed; this says which station it is and when
                // it was last on the air.
                note(heardDescription(match), symbol: "checkmark.circle", tint: .secondary)
            } else if !model.normalizedTo.isEmpty, !model.isHeard(in: heardStations) {
                // Worth saying, not worth blocking: an i-gate may still carry
                // it, but on RF from here it is going nowhere.
                note("Not heard here. An i-gate may still carry it, but nothing on RF "
                     + "within your range has been heard from this station.",
                     symbol: "questionmark.circle", tint: .secondary)
            }
        }
    }

    private var suggestions: [APRSComposeModel.Suggestion] {
        model.suggestions(from: heardStations)
    }

    // MARK: - Message

    private var message: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Message").font(.subheadline.weight(.medium))
                Spacer()
                // Counted down rather than up: what matters is how much room
                // is left, and a limit this tight is a constraint the operator
                // writes against.
                Text("\(model.remainingCharacters) left")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.isOverLength ? Color.red : .secondary)
            }

            TextField("", text: $model.text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .focused($focus, equals: .text)

            if model.isOverLength {
                note("APRS allows \(APRSMessage.maxTextLength) characters. Shorten it by "
                     + "\(-model.remainingCharacters) before sending.",
                     symbol: "exclamationmark.triangle.fill", tint: .red)
            } else {
                note("One transmission, no delivery guarantee. The station acknowledges it or "
                     + "it is retried; nothing else confirms it arrived.",
                     symbol: "info.circle", tint: .secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Send") { send() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
        }
        .padding(18)
    }

    private func send() {
        guard model.canSend else { return }
        onSend(model.normalizedTo, model.outgoingText)
        dismiss()
    }

    private func heardDescription(_ station: APRSComposeModel.Suggestion) -> String {
        var parts: [String] = []
        if let heard = station.lastHeard {
            parts.append("Heard " + RelativeDateTimeFormatter().localizedString(
                for: heard, relativeTo: Date()))
        } else {
            parts.append("Known, not heard recently")
        }
        if let via = station.via { parts.append("via \(via)") }
        return parts.joined(separator: " \u{b7} ")
    }

    @ViewBuilder
    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(tint)
    }
}

private extension View {
    /// Callsigns are upper-case and never autocorrected.
    @ViewBuilder func callsignInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.characters).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
