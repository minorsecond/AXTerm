import CoreGraphics

/// Whether a packet list is showing its newest row. Pure, so the tolerance
/// can be tested.
nonisolated enum PacketListFollow {
    /// Within a row's height of the end counts as the end: the last row
    /// half off the screen is still "following".
    static let tolerance: CGFloat = 40

    /// An upward move this small with nobody scrolling is the layout
    /// settling, not a reader (finding 42: one point stopped the iPad's
    /// terminal following). A wheel notch or a swipe moves far more.
    static let layoutNoise: CGFloat = 3

    static func isAtBottom(contentHeight: CGFloat, visibleMaxY: CGFloat) -> Bool {
        visibleMaxY >= contentHeight - tolerance
    }
}

/// Follow new rows only while the reader is at the bottom.
///
/// A list that follows whenever new rows arrive pulls a reader back to the
/// bottom on every one; on a session with a keep-alive poll every 30 s that
/// made scrolling back through the log nearly impossible. Scrolling up stops
/// following, new rows then leave the view alone, and getting back to the
/// bottom starts it again.
nonisolated extension PacketListFollow {
    /// A scroll view's geometry, reduced to what following needs.
    struct Geometry: Equatable, Sendable {
        var contentHeight: CGFloat
        var visibleMinY: CGFloat
        var visibleHeight: CGFloat
        var visibleWidth: CGFloat = 0

        /// - Parameter trailingSpace: padding below the last row, left out
        ///   of the content so the end is the last row. The re-pin puts the
        ///   last row at the foot of the view; counted in, the padding kept
        ///   that position from ever being the bottom, and the next nudge
        ///   stopped following for good (park rehearsal 2026-10-08,
        ///   finding 42).
        init(contentHeight: CGFloat, visibleMinY: CGFloat, visibleHeight: CGFloat,
             visibleWidth: CGFloat = 0, trailingSpace: CGFloat = 0) {
            self.contentHeight = max(0, contentHeight - trailingSpace)
            self.visibleMinY = visibleMinY
            self.visibleHeight = visibleHeight
            self.visibleWidth = visibleWidth
        }

        var isAtBottom: Bool {
            PacketListFollow.isAtBottom(contentHeight: contentHeight,
                                        visibleMaxY: visibleMinY + visibleHeight)
        }
    }

    struct Decision: Equatable, Sendable {
        var isFollowing: Bool
        /// Scroll to the newest row now: it moved off screen while following.
        var scrollToNewest: Bool
    }

    /// What to do when the scroll geometry changes from `old` to `new`.
    ///
    /// The scroll phase is not enough on its own: a mouse wheel on the Mac
    /// can move the view without one. So a move up of less than a screen
    /// counts as the reader too. A bigger jump with nobody scrolling is not
    /// the reader: the iPhone tab view resets a hidden list to the top when
    /// its tab comes forward. A follower is put back after that.
    static func decide(from old: Geometry, to new: Geometry,
                       isFollowing: Bool, userIsScrolling: Bool) -> Decision {
        if new.isAtBottom {
            return Decision(isFollowing: true, scrollToNewest: false)
        }
        let movedUp = old.visibleMinY - new.visibleMinY
        // The view itself changed size (the screen turned, the window or the
        // keyboard moved): the lines reflowed under it and nobody scrolled.
        // Taken for the reader, that stopped the iPad's terminal following
        // (smoke run 2026-10-03-1, issue 116).
        let viewResized = new.visibleHeight != old.visibleHeight || new.visibleWidth != old.visibleWidth
        if userIsScrolling || (movedUp > layoutNoise && movedUp < new.visibleHeight && !viewResized) {
            return Decision(isFollowing: false, scrollToNewest: false)
        }
        // New rows, a resized window, or a jump nobody made. Only a follower
        // is moved; a reader stays where they are.
        let resized = new.contentHeight != old.contentHeight || new.visibleHeight != old.visibleHeight
        let jumped = movedUp > 0
        return Decision(isFollowing: isFollowing, scrollToNewest: isFollowing && (resized || jumped))
    }
}
