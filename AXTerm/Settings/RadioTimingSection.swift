import SwiftUI

/// A radio's KISS timing: TX delay, persistence, slot time and TX tail.
///
/// One section for every transport, bound to the four `RadioProfile` fields.
/// How the values reach the air depends on what the radio is reached by
/// (`RadioProfile.timingDelivery`):
///
/// * the sound modem uses them itself when it keys the radio;
/// * a Bluetooth LE TNC or a serial Mobilinkd is sent them by its link every
///   time it connects, and again when they change;
/// * a network TNC (Direwolf) or a plain serial TNC is left alone unless the
///   operator switches on "Send these to the TNC", and then `RadioManager`
///   sends them on connect and on change.
struct RadioTimingSection: View {
    @ObservedObject var viewModel: ConnectionTransportViewModel
    let delivery: RadioProfile.TimingDelivery

    private var sent: Bool { Self.fieldsEditable(delivery: delivery, sendsTiming: viewModel.sendsKISSTiming) }

    /// Whether the four values can be edited. Only when something uses them:
    /// with "Send these to the TNC" off nothing is sent, so the fields are
    /// dimmed and locked, keeping their values for when it is switched on.
    nonisolated static func fieldsEditable(delivery: RadioProfile.TimingDelivery, sendsTiming: Bool) -> Bool {
        delivery != .optional || sendsTiming
    }

    var body: some View {
        Section {
            if delivery == .optional {
                Toggle("Send these to the TNC", isOn: $viewModel.sendsKISSTiming)
                    .help("Off, the TNC keeps the timing it was set up with; for Direwolf that "
                          + "is TXDELAY, PERSIST, SLOTTIME and TXTAIL in direwolf.conf. On, "
                          + "AXTerm sends the values below as KISS commands on this radio's "
                          + "port each time it connects, and again when you change one.")
            }
            // Disabled row by row: on iOS a `.disabled` on a Group around
            // the rows left every field editable.
            row("TX delay", value: $viewModel.txDelayMs, unit: "ms", range: 0...2000, step: 10,
                help: Self.txDelayHelp)
            row("Persistence", value: $viewModel.persistence, unit: "", range: 0...255, step: 1,
                help: Self.persistenceHelp)
            row("Slot time", value: $viewModel.slotTimeMs, unit: "ms", range: 10...1000, step: 10,
                help: Self.slotTimeHelp)
            row("TX tail", value: $viewModel.txTailMs, unit: "ms", range: 0...1000, step: 10,
                help: Self.txTailHelp)
        } header: {
            Text("Timing")
        } footer: {
            Text(Self.footer(delivery: delivery, sendsTiming: viewModel.sendsKISSTiming))
        }
        .id(SettingsSection.radioTiming)
    }

    /// What happens to the values, for the line under the section.
    nonisolated static func footer(delivery: RadioProfile.TimingDelivery, sendsTiming: Bool) -> String {
        switch delivery {
        case .modem:
            return "AXTerm's sound modem uses these itself when it keys the radio. A change "
                + "applies from the next transmission."
        case .sentByLink:
            return "Sent to the TNC every time this radio connects, and straight away when "
                + "you change one while it is connected."
        case .optional where sendsTiming:
            return "Sent to the TNC every time this radio connects, and straight away when you "
                + "change one. The TNC keeps them until it restarts; for Direwolf they replace "
                + "the direwolf.conf values for this channel."
        case .optional:
            return "The TNC is using its own timing, so these values are not sent."
        }
    }

    nonisolated static let txDelayHelp =
        "How long the transmitter is keyed before the first frame starts, in milliseconds, "
        + "so the radio is fully on the air before any data goes out. Too short and the start "
        + "of every frame is lost. 300 ms suits most radios; a slow handheld needs more (an "
        + "Icom IC-V8 needs 500 ms), and a radio that switches fast can manage 100 ms. KISS "
        + "carries it in 10 ms steps."

    nonisolated static let persistenceHelp =
        "The chance, out of 256, that the TNC transmits in a given slot once the channel is "
        + "clear (p-persistence). 63 means about one slot in four, the usual value on a shared "
        + "channel. Higher grabs the channel sooner and collides more; 255 always transmits "
        + "at once. Lower it on a busy channel."

    nonisolated static let slotTimeHelp =
        "How long the TNC waits between persistence tries, in milliseconds. 100 ms is usual. "
        + "A longer slot makes the station more patient on a busy channel. KISS carries it in "
        + "10 ms steps."

    nonisolated static let txTailHelp =
        "How long the transmitter stays keyed after the last frame, in milliseconds, so the "
        + "end of the frame is not cut off when PTT drops. 10 to 100 ms is usual; a sound card "
        + "with audio latency needs more. Some hardware TNCs ignore it."

    private func row(_ title: String, value: Binding<Int>, unit: String,
                     range: ClosedRange<Int>, step: Int, help: String) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number)
                    .labelsHidden()
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .disabled(!sent)
                Stepper(title, value: value, in: range, step: step)
                    .labelsHidden()
                    .disabled(!sent)
                // Every row keeps the unit column, so Persistence, which has
                // no unit, lays out on one line like the other three.
                Text(unit.isEmpty ? "ms" : unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
                    .opacity(unit.isEmpty ? 0 : 1)
                    .accessibilityHidden(unit.isEmpty)
            }
            .opacity(sent ? 1 : 0.5)
        } label: {
            Text(title)
                .foregroundStyle(sent ? .primary : .secondary)
        }
        .help(help)
    }
}
