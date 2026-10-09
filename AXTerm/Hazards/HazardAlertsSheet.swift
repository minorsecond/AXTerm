import SwiftUI

/// The alerts under a tap on the map: one opens straight to its card,
/// several are listed most urgent first.
struct HazardAlertsSheet: View {
    let features: [HazardFeature]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let cards = features.map { HazardText.detail($0, now: context.date) }
                Group {
                    if cards.count == 1, let card = cards.first {
                        HazardAlertCard(card: card)
                    } else {
                        List(cards) { card in
                            NavigationLink {
                                HazardAlertCard(card: card)
                            } label: {
                                HazardAlertRow(card: card)
                            }
                        }
                    }
                }
                .navigationTitle(cards.count == 1 ? (cards.first?.title ?? "Alert") : "\(cards.count) Alerts Here")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 420, idealHeight: 600)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

private struct HazardAlertRow: View {
    let card: HazardDetail

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hazardHex: card.hex))
                .frame(width: 6, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.headline)
                Text(card.timing)
                    .font(.caption)
                    .foregroundStyle(card.expired ? .red : .secondary)
                if let area = card.area {
                    Text(area).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(card.expired ? 0.6 : 1)
    }
}

/// One alert in the agency's own words, with its times, area, and where the
/// copy came from.
struct HazardAlertCard: View {
    let card: HazardDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hazardHex: card.hex))
                        .frame(width: 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title).font(.title2.weight(.semibold))
                        Label(card.timing, systemImage: card.expired ? "clock.badge.xmark" : "clock")
                            .font(.subheadline)
                            .foregroundStyle(card.expired ? .red : .primary)
                        if let severity = card.severity {
                            Text(severity).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if let headline = card.headline {
                    Text(headline).font(.callout).foregroundStyle(.secondary)
                }
                if let area = card.area {
                    section("Area") { Text(area) }
                }
                if !card.description.isEmpty {
                    section("What") { paragraphs(card.description) }
                }
                if !card.instruction.isEmpty {
                    section("What to do") { paragraphs(card.instruction) }
                }
                Text(card.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    /// Bullets ("* ", "- ") as an indented list; the rest as paragraphs.
    private func paragraphs(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("- ") {
                    Text("•  " + line.dropFirst(2)).padding(.leading, 14)
                } else if line.hasPrefix("* ") {
                    Text(line.dropFirst(2)).fontWeight(.medium)
                } else {
                    Text(line)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension Color {
    /// An NWS hazard color, six hex digits (`NWSHazardStyle`).
    init(hazardHex hex: String) {
        let rgb = HazardOverlayBuilder.rgb(hex) ?? (red: 0.66, green: 0.66, blue: 0.66)
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
