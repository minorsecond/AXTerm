import SwiftUI

/// One radio in the sidebar: how its link is doing, who it is on the air,
/// whether it is talking, and a switch that shows or hides its traffic
/// everywhere — the Packets table, the console, the map, the analytics.
///
/// The switch is visibility, not power: a hidden radio still receives, still
/// counts, still answers calls. It is only not drawn, so an operator with a
/// busy VHF channel and a quiet UHF one can look at either without losing
/// the other.
struct RadioRowView: View {
    let radio: RadioStatusSummary
    @Binding var isShown: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .help(RadioPresentation.dotHelp(radio))

            VStack(alignment: .leading, spacing: 1) {
                Text(radio.name)
                    .font(.system(.subheadline))
                    .lineLimit(1)
                if !radio.callsign.isEmpty {
                    Text(radio.callsign)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                Blinkenlight(color: .green, trigger: radio.lastRx ?? .distantPast)
                    .help("RX on \(radio.name)")
                Blinkenlight(color: .red, trigger: radio.lastTx ?? .distantPast)
                    .help("TX on \(radio.name)")
            }

            Toggle("", isOn: $isShown)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(isShown
                      ? "Showing \(radio.name)'s traffic. Switch off to hide it everywhere; the radio keeps receiving."
                      : "\(radio.name)'s traffic is hidden everywhere. The radio is still receiving and answering.")
        }
        .opacity(isShown ? 1 : 0.6)
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch RadioPresentation.tint(for: radio.status) {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: Color(platform: .platformTertiaryLabel)
        }
    }
}
