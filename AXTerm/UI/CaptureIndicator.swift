import Foundation

/// The words beside a running capture's red symbol.
///
/// The symbol's explanation is a hover tooltip, which a touch screen never
/// shows: on the iPad a running capture was an unexplained red dot (smoke
/// run 2026-10-03-1, issue 117). A touch device names it; with a pointer
/// the tooltip stays the explanation.
nonisolated enum CaptureIndicator {
    static func caption(isCapturing: Bool, touch: Bool) -> String? {
        isCapturing && touch ? "Capturing" : nil
    }

    #if os(iOS)
    static let isTouch = true
    #else
    static let isTouch = false
    #endif
}
