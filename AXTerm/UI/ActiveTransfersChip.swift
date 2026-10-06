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
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
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
        case .outbound: return "arrow.up.circle"
        case .inbound: return "arrow.down.circle"
        case nil: return "arrow.up.arrow.down.circle"
        }
    }
}
