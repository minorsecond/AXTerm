import Foundation

/// The note shown once when a connected link has been polled for a while and
/// has carried no data.
///
/// What it may say depends on the evidence. An ack of something we sent
/// proves both directions carry frames. An answer to one of our own polls
/// proves the same. Only a poll of ours that went unanswered is a reason to
/// suggest the far end may not be hearing us. The peer's polls, which we
/// answer, show only that we hear the peer.
///
/// Live RF test 2026-09-30: both stations answered every 30 s keepalive poll
/// and the note still said the far end "may not be answering".
nonisolated enum IdleLinkNotice {

    static func text(display: String, route: String, polls: Int,
                     acknowledged: Bool, pollEvidence: AX25PollEvidence) -> String {
        let station = "\(display) (\(route))"
        if acknowledged {
            // An ack proves both directions carry frames, so a link that acks
            // and then says nothing is a peer whose application is not
            // answering. Reporting that as a one-way path would send the
            // operator hunting for a better route they do not need.
            return "\(station) acknowledged what you sent but has not answered "
                + "in \(polls) polls. The link is good. The far end is not replying."
        }
        switch pollEvidence {
        case .answered:
            return "\(station) is connected and answering polls. No data has passed "
                + "in either direction yet."
        case .unanswered:
            return "\(station) is connected, but no data has passed in either direction "
                + "and it has not answered this station's last poll. The far end may "
                + "not be hearing this station on this path."
        case .none:
            return "\(station) is connected and polling. No data has passed "
                + "in either direction yet."
        }
    }
}
