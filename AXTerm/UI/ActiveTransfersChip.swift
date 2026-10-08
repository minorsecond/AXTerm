import SwiftUI

/// A file transfer under way, kept in view wherever the operator is: with
/// the toolbar's status pills on the Mac, above the status strip on iPhone
/// and iPad. Clicking it opens the Terminal's Transfers tab, where the full
/// progress and the controls are (smoke run 2026-10-03-1, issue 91).
struct ActiveTransfersChip: View {
    let summary: ActiveTransfersSummary
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                // A plain arrow, secondary: the progress bar is the
                // accent, and a circled glyph in accent read as an info
                // badge (operator, 2026-10-07).
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let fraction = summary.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 44)
                }
                Text(summary.label)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .frame(maxWidth: 260)
            .fixedSize(horizontal: false, vertical: true)
            .toolbarPill()
        }
        .buttonStyle(.plain)
        .help("\(summary.detail). Click to see transfers.")
        .accessibilityLabel(summary.detail)
        .accessibilityHint("Shows the Transfers tab")
    }

    private var symbol: String {
        switch summary.direction {
        case .outbound: return "arrow.up"
        case .inbound: return "arrow.down"
        case nil: return "arrow.up.arrow.down"
        }
    }
}

#if os(iOS)
/// The iPhone and iPad version: a full-width card above the status strip,
/// on every tab, with a bar and a line that can be read at arm's length
/// (park rehearsal 2026-10-08: the chip's thin bar and percent were too
/// small, and the full progress lived only on the Transfers tab). Tapping it
/// still opens the Transfers tab.
struct ActiveTransferCard: View {
    let summary: ActiveTransfersSummary
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: summary.direction == .outbound ? "arrow.up"
                          : summary.direction == .inbound ? "arrow.down" : "arrow.up.arrow.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(summary.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let fraction = summary.fraction {
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                }
                if let fraction = summary.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .scaleEffect(x: 1, y: 1.6, anchor: .center)
                }
                Text(summary.progressLine ?? summary.detail)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary.detail + (summary.progressLine.map { ", " + $0 } ?? ""))
        .accessibilityHint("Shows the Transfers tab")
    }
}
#endif
