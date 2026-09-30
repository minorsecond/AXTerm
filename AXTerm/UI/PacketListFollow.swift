import CoreGraphics

/// Whether a packet list is showing its newest row. Pure, so the tolerance
/// can be tested.
nonisolated enum PacketListFollow {
    /// Within a row's height of the end counts as the end: the last row
    /// half off the screen is still "following".
    static let tolerance: CGFloat = 40

    static func isAtBottom(contentHeight: CGFloat, visibleMaxY: CGFloat) -> Bool {
        visibleMaxY >= contentHeight - tolerance
    }
}
