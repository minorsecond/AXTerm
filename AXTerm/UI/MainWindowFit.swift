#if os(macOS)
import AppKit
import SwiftUI

/// Keeps the main window on its screen.
///
/// On a 1920x1080 display Zoom made the window 1,440 tall, hanging the
/// compose bar off the bottom of the screen, and zooming back laid the
/// content out for the old height and slid it up under the title bar
/// (operator, 2026-10-10). Whatever sets a frame larger than the screen
/// (Zoom, a restored frame, a window manager, a change of display) is
/// clamped back to the screen's usable area.
enum MainWindowFit {

    /// The frame moved and shrunk to fit `visible`, or nil when it fits.
    /// The top edge stays where it was when it can, so a window that ran
    /// off the bottom keeps its title bar in place.
    static func clamped(_ frame: NSRect, visible: NSRect) -> NSRect? {
        var fitted = frame
        fitted.size.width = min(fitted.width, visible.width)
        fitted.size.height = min(fitted.height, visible.height)
        // Keep the top where it was, but not above the usable area.
        let top = min(frame.maxY, visible.maxY)
        fitted.origin.y = top - fitted.height
        if fitted.minY < visible.minY { fitted.origin.y = visible.minY }
        if fitted.minX < visible.minX { fitted.origin.x = visible.minX }
        if fitted.maxX > visible.maxX { fitted.origin.x = visible.maxX - fitted.width }
        return fitted == frame ? nil : fitted
    }
}

/// Watches the window it sits in and applies `MainWindowFit` after every
/// resize, move or change of screen. Full screen is left alone.
struct MainWindowFitter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FitterView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class FitterView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                         NSWindow.didChangeScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated { if let window { Self.fit(window) } }
                })
            }
            DispatchQueue.main.async { [weak window] in if let window { Self.fit(window) } }
        }

        @MainActor
        static func fit(_ window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen),
                  let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
                  let fitted = MainWindowFit.clamped(window.frame, visible: visible) else { return }
            window.setFrame(fitted, display: true, animate: false)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
#endif
