import Foundation

/// Broadcasting to everyone on the channel, rather than to one station.
///
/// Objects say *where*. Bulletins say *what*: `Net control 147.105, check in`,
/// `Shelter open at the high school`. They carry no addressee anyone answers
/// to, are never acked, and every client shows them apart from ordinary
/// traffic — which is exactly what a net announcement needs and what a
/// person-to-person message cannot do.
///
/// **A bulletin identifier is a slot, and the slot is per station.** `BLN1`
/// from this station and `BLN1` from another are two different bulletins;
/// re-sending our own `BLN1` replaces our own earlier one on every receiver.
/// That is the opposite of an object name, which is a key across the whole
/// channel — see `APRSObjectPlacement`. Nobody can overwrite our bulletin and
/// we cannot overwrite theirs, so there is no collision check here and there
/// should not be one.
nonisolated enum APRSBulletin {

    /// `0`–`9`: an ordinary bulletin. Several in sequence are how a message
    /// longer than one frame is sent, and clients display them in order.
    static let bulletinIdentifiers = Array("0123456789")

    /// `A`–`Z`: an announcement. Same wire format; the convention is that it
    /// is longer-lived and re-sent far less often.
    static let announcementIdentifiers = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// A group narrows who a bulletin is meant for — `BLN1ARES` is bulletin 1
    /// of the ARES group. `BLN` plus the identifier leaves five characters.
    static let maxGroupLength = 5

    /// Why a bulletin must not go out as typed.
    enum Problem: Equatable, Sendable {
        case emptyText
        case textTooLong(over: Int)
        case badIdentifier
        case badGroup
        /// APRS reserves these in message text: `{` opens a message number, and
        /// `|` and `~` are reserved by the spec. A bulletin carrying one is
        /// read as something else by somebody.
        case reservedCharacter(Character)

        var message: String {
            switch self {
            case .emptyText:
                return "A bulletin needs something to say."
            case .textTooLong(let over):
                return "\(over) character\(over == 1 ? "" : "s") too long. A bulletin holds "
                    + "\(APRSMessage.maxTextLength); send the rest as the next slot."
            case .badIdentifier:
                return "A bulletin is 0\u{2013}9 and an announcement is A\u{2013}Z."
            case .badGroup:
                return "A group is up to \(maxGroupLength) letters or digits, or nothing at all."
            case .reservedCharacter(let c):
                return "APRS reserves \u{201C}\(c)\u{201D} in message text \u{2014} it would be "
                    + "read as part of the protocol rather than as what you wrote."
            }
        }
    }

    /// Characters the spec keeps for itself inside message text.
    static let reserved: Set<Character> = ["{", "|", "~"]

    /// The check to run before offering to transmit.
    static func problem(identifier: Character, group: String, text: String) -> Problem? {
        guard bulletinIdentifiers.contains(identifier)
                || announcementIdentifiers.contains(identifier) else { return .badIdentifier }
        let g = group.trimmingCharacters(in: .whitespaces)
        guard g.count <= maxGroupLength,
              g.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .badGroup }
        let body = text.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return .emptyText }
        if let bad = body.first(where: { reserved.contains($0) }) {
            return .reservedCharacter(bad)
        }
        guard body.count <= APRSMessage.maxTextLength else {
            return .textTooLong(over: body.count - APRSMessage.maxTextLength)
        }
        return nil
    }

    /// `BLN` + identifier + group. `APRSMessage.messageInfo` pads it to the
    /// nine characters the addressee field is.
    static func addressee(identifier: Character, group: String) -> String {
        "BLN" + String(identifier).uppercased()
            + group.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// `:BLNnGROUP:text` — no message number, because a bulletin is never
    /// acked and asking for one would have every station on the channel
    /// answering at once.
    static func info(identifier: Character, group: String, text: String) -> String {
        APRSMessage.messageInfo(to: addressee(identifier: identifier, group: group),
                                text: text.trimmingCharacters(in: .whitespaces),
                                number: nil)
    }
}
