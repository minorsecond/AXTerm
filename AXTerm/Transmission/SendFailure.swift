import Foundation

/// Telling "the radio is not there" apart from "something went wrong".
///
/// Both arrive at the same callback as an `Error`, and for a long time both
/// were reported the same way — at error level, straight to Sentry. On
/// 2026-09-18 that produced thirty-two transport-level and twenty
/// session-level reports across one night, every one of them saying a frame
/// could not be sent, none of them saying why, and nothing at all saying that
/// the station had been off the air since eight in the evening.
///
/// A node beaconing every half hour into a link that is down will keep
/// discovering the link is down. That is a consequence with its own report
/// (`LinkOutageWatch`), so here it is a breadcrumb.
nonisolated enum SendFailure {

    /// Whether this failure means the link was not up, as opposed to the link
    /// being up and the send going wrong on it.
    static func isLinkDown(_ error: Error) -> Bool {
        if let transport = error as? KISSTransportError {
            switch transport {
            case .notConnected: return true
            case .connectionFailed, .sendFailed: return false
            }
        }
        return false
    }
}
