import SwiftUI

/// A console row whose message drops under the callsigns when it would wrap.
///
/// Three children: the time, the header (callsigns and chips), and the
/// message. When the message fits beside the header on one line, the row is
/// one line, as before. When it would not, wrapping it in the narrow column
/// right of the header made a tall ribbon of text at the far side of the
/// window. Here it moves to a second row instead, starting under the first
/// callsign, with the full width to itself.
struct ConsoleRowLayout: Layout {
    var spacing: CGFloat = 6
    /// Between the header row and a message placed under it.
    var rowGap: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(width proposed: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        guard subviews.count == 3 else {
            // Not the shape this layout is for: stack whatever it was given.
            var y: CGFloat = 0
            var frames: [CGRect] = []
            var widest: CGFloat = 0
            for subview in subviews {
                let size = subview.sizeThatFits(ProposedViewSize(width: proposed, height: nil))
                frames.append(CGRect(origin: CGPoint(x: 0, y: y), size: size))
                y += size.height
                widest = max(widest, size.width)
            }
            return (CGSize(width: proposed ?? widest, height: y), frames)
        }

        let time = subviews[0].sizeThatFits(.unspecified)
        let header = subviews[1].sizeThatFits(.unspecified)
        let messageIdeal = subviews[2].sizeThatFits(.unspecified)
        let leading = time.width + spacing + header.width
        let width = proposed ?? (leading + spacing + messageIdeal.width)

        switch ConsoleRowArrangement.choose(leadingWidth: leading, messageWidth: messageIdeal.width,
                                            available: width, spacing: spacing) {
        case .singleRow:
            let messageWidth = max(width - leading - spacing, 0)
            let message = subviews[2].sizeThatFits(ProposedViewSize(width: messageWidth, height: nil))
            let height = max(time.height, header.height, message.height)
            return (CGSize(width: width, height: height), [
                CGRect(origin: .zero, size: time),
                CGRect(origin: CGPoint(x: time.width + spacing, y: 0), size: header),
                CGRect(x: leading + spacing, y: 0, width: messageWidth, height: message.height),
            ])
        case .messageBelow:
            let indent = time.width + spacing
            let messageWidth = max(width - indent, 0)
            let message = subviews[2].sizeThatFits(ProposedViewSize(width: messageWidth, height: nil))
            let firstRow = max(time.height, header.height)
            return (CGSize(width: width, height: firstRow + rowGap + message.height), [
                CGRect(origin: .zero, size: time),
                CGRect(origin: CGPoint(x: indent, y: 0), size: header),
                CGRect(x: indent, y: firstRow + rowGap, width: messageWidth, height: message.height),
            ])
        }
    }
}
