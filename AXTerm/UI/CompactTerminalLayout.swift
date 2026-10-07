//
//  CompactTerminalLayout.swift
//  AXTerm
//
//  How the terminal arranges itself at phone width. Smoke run 2026-10-03-1,
//  issue 106: on an iPhone the tab row was wider than the screen, so the
//  whole terminal page rendered wider than the display and was clipped at
//  both edges; the compose area was four rows of controls around a message
//  field about 70 points wide; and console rows kept their time and calls in
//  a left column, wrapping a long line three words per row.
//
//  The decisions live here, apart from the views, so the Mac's tests can
//  check them; the views only read them.
//

import Foundation

nonisolated enum CompactTerminalLayout {

    /// Where the session picker goes in the terminal's top row.
    enum SessionControl: Equatable {
        /// Nothing to pick, or not the session pane.
        case none
        /// The picker and Clear Closed beside the tabs (a Mac or an iPad).
        case inline
        /// One menu button beside the tabs: the sessions and Clear Closed.
        case menu
    }

    static func sessionControl(tab: TerminalTab, hasRecords: Bool, compact: Bool) -> SessionControl {
        guard tab == .session, hasRecords else { return .none }
        return compact ? .menu : .inline
    }

    /// Which compose-area rows are drawn.
    struct ComposeRows: Equatable {
        /// The destination field and the route capsule.
        var destination: Bool
        /// Auto, Direct, Digi, NET/ROM.
        var routingPicker: Bool
        /// Line/Raw, control keys, position and capture in one menu beside
        /// the field, so the field gets the width.
        var accessoriesInMenu: Bool
    }

    /// On a phone, a link that is up fixes both who and how: the station is
    /// named in the session header, and the route cannot change without a
    /// reconnect. Those rows are dropped until the link ends.
    static func composeRows(compact: Bool, sessionMode: Bool, linkUp: Bool) -> ComposeRows {
        guard compact else {
            return ComposeRows(destination: sessionMode, routingPicker: sessionMode, accessoriesInMenu: false)
        }
        let choosing = sessionMode && !linkUp
        return ComposeRows(destination: choosing, routingPicker: choosing, accessoriesInMenu: true)
    }

    /// The session strip shows in Session mode, and in Broadcast mode while a
    /// link is up: switching the bar to Broadcast does not end the link, and
    /// hiding the strip made a live session look gone.
    static func showsSessionStrip(sessionMode: Bool, linkUp: Bool) -> Bool {
        sessionMode || linkUp
    }

    /// A phone puts the message under its time and calls instead of beside
    /// them, so a long line wraps at the screen's width.
    static func stacksMessageUnderHeader(compact: Bool) -> Bool { compact }
}

/// When the TX queue panel is on screen.
nonisolated enum TxQueuePresentation {
    /// Only while something is still going out. Finished entries alone used
    /// to keep the panel open at up to 200 points, which on a phone was half
    /// the terminal and hid the newest lines.
    static func isVisible(statuses: [TxFrameStatus]) -> Bool {
        statuses.contains { status in
            switch status {
            case .queued, .sending, .awaitingAck: return true
            case .sent, .acked, .failed, .cancelled: return false
            }
        }
    }
}
