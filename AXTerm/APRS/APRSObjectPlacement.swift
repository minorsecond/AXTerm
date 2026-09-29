import Foundation

/// What an operator is about to put on the channel, and whether they should.
///
/// Placing an object is the only thing in the map that transmits on someone
/// else's behalf: the frame goes to every station in range and lands in every
/// receiver's object list under a name that is a *global key on the channel*.
/// There is no authentication anywhere in it. So the two questions worth
/// asking before the radio keys are whose name this is about to take, and
/// whose object this is about to remove.
nonisolated enum APRSObjectPlacement {

    /// Why a placement must not go out as typed.
    enum Problem: Equatable, Sendable {
        /// Nothing survives the characters the wire format forbids.
        case unusableName
        /// Another station has a live object by this name. APRS keys objects
        /// by name alone, so transmitting would replace theirs on every
        /// receiver on the channel — in an incident net, one agency's marker
        /// silently overwriting another's.
        case collidesWith(station: String)

        var message: String {
            switch self {
            case .unusableName:
                return "That name has nothing left in it once the characters APRS reserves "
                    + "are removed. Objects are named with letters, digits and punctuation "
                    + "other than ! _ ; and )."
            case .collidesWith(let station):
                return "\(station) already has a live object with this name. APRS keys objects "
                    + "by name alone, so sending this would replace theirs on every station "
                    + "on the channel. Pick another name."
            }
        }
    }

    /// The check to run before offering to transmit.
    ///
    /// Case- and padding-insensitive, because that is how the key works: an
    /// object called "Fire" and one called "FIRE  " are one object as far as
    /// every other implementation is concerned.
    static func problem(name: String,
                        liveObjects: [APRSObjectStore.Placed],
                        ourAddresses: Set<String>) -> Problem? {
        guard APRSObjectReport.isTransmittableName(name) else { return .unusableName }
        let key = APRSObjectReport.wireName(name)
            .trimmingCharacters(in: .whitespaces).uppercased()
        let ours = Set(ourAddresses.map { $0.uppercased() })
        // Replacing our *own* object is how an object is moved or its comment
        // corrected — the format has no other way to do it, so it is not a
        // collision.
        if let clash = liveObjects.first(where: {
            $0.report.key == key && !ours.contains($0.reportedBy.uppercased())
        }) {
            return .collidesWith(station: clash.reportedBy)
        }
        return nil
    }

    /// Whether this station may offer to remove an object.
    ///
    /// APRS lets anyone kill anything — the protocol has no notion of
    /// ownership and a kill from a stranger is honoured by every receiver.
    /// That is exactly why the button is not offered: an operator who can
    /// stand down another agency's road closure with one click will
    /// eventually do it by accident. Removing someone else's object is a
    /// decision that should cost more than a click, and it is one this app
    /// declines to make easy.
    static func mayRemove(_ placed: APRSObjectStore.Placed,
                          ourAddresses: Set<String>) -> Bool {
        Set(ourAddresses.map { $0.uppercased() }).contains(placed.reportedBy.uppercased())
    }

    /// What removing actually does, said plainly. A kill is a transmission,
    /// not a local delete, and an operator who thinks otherwise will be
    /// surprised by which map it disappears from.
    static func removalExplanation(_ placed: APRSObjectStore.Placed) -> String {
        "Transmits a kill for \u{201C}\(placed.report.name)\u{201D} \u{2014} it disappears "
            + "from every station on the channel that hears it, not just from this map."
    }
}
