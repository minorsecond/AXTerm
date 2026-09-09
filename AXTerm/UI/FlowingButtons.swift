import SwiftUI

/// Lays its children out in a row and wraps to the next line when they run out
/// of width.
///
/// The station card had four fixed-size buttons in an `HStack`. On a narrow
/// card — which is every card on a phone, and a Mac card beside a wide
/// inspector — SwiftUI shrank them until their labels were clipped to
/// "Co\u{2026}", "Ope\u{2026}", "Mes\u{2026}". A button whose label has been
/// truncated to three characters is not a button an operator can use in a
/// hurry, and this is a card people will be reading in a hurry.
///
/// Wrapping rather than scrolling: a hidden action is worse than a taller
/// card, and the card already sizes to its content.
struct FlowingButtons<Content: View>: View {

    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        // Reuses the flow layout the analytics dashboard already ships.
        FlowLayout(spacing: spacing) { content }
    }
}

/// A layout that wraps content to the next row when it doesn't fit.
///
/// Shared: the analytics dashboard's responsive controls and the map's station
/// card both need it, so it lives here rather than privately inside whichever
/// view happened to want it first.
nonisolated struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(subviews: subviews, proposal: proposal)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, proposal: proposal)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(subviews: Subviews, proposal: ProposedViewSize) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                // Move to next row
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, currentX - spacing)
        }

        totalHeight = currentY + rowHeight
        return (CGSize(width: totalWidth, height: totalHeight), positions)
    }
}
