import Foundation

/// What a Kantronics KA-Node's command prompt actually offers.
///
/// The node states its command set and nothing more — `ENTER COMMAND:
/// B,C,J,N, or Help ?` — and the one command that would explain the others
/// costs airtime on a shared channel to ask. AXTerm knows this software
/// family with certainty when `NodeCapabilityDirectory.family(for:)` says
/// `.kaNode`, so it can answer locally instead.
///
/// The rule: explain the letters *this* node offered, and only those. A
/// canned Kantronics list would describe commands a particular node may not
/// have, and the operator would find out by keying up and getting an error
/// on the air for a command AXTerm invented. A letter we do not recognise is
/// reported as unrecognised rather than guessed at.
nonisolated enum KaNodeCommandHelp {

    struct Command: Equatable, Sendable {
        let letter: String
        let name: String
        let summary: String
    }

    struct Explanation: Equatable, Sendable {
        /// Offered by this node and known to us, in the order offered.
        let commands: [Command]
        /// Offered by this node and *not* known to us. Named so the operator
        /// can see there is more here than AXTerm can explain.
        let unrecognised: [String]
    }

    /// The Kantronics command set, as documented by its own prompt.
    ///
    /// `J` and `N` are the pair worth being careful about: one is a
    /// measurement and the other a directory, and treating a directory as
    /// RF-heard is how second-hand names become claims about coverage.
    private static let known: [String: Command] = [
        "B": Command(letter: "B", name: "Bye",
                     summary: "Disconnect from this node."),
        "C": Command(letter: "C", name: "Connect",
                     summary: "Ask this node to connect you onward — `C <callsign>`. "
                            + "The far station's own prompts appear here afterwards."),
        "J": Command(letter: "J", name: "JHeard",
                     summary: "Stations this node heard directly on RF — one hop from "
                            + "its own antenna, so it measures what this node can reach."),
        "N": Command(letter: "N", name: "Nodes",
                     summary: "Other nodes this node knows of, by alias and callsign. "
                            + "A directory, some of it learned second-hand, so it is not "
                            + "proof any of them are reachable right now."),
    ]

    /// Whether this line is a Kantronics command prompt.
    ///
    /// Deliberately narrow. "ENTER COMMAND" alone is a generic prompt other
    /// software prints too; the offered-letter list is what makes it
    /// Kantronics, and it is also the thing being explained.
    static func isCommandPrompt(_ line: String) -> Bool {
        offeredLetters(in: line) != nil
    }

    /// The explanation for a prompt, or nil when the line is not one.
    static func explain(_ line: String) -> Explanation? {
        guard let letters = offeredLetters(in: line) else { return nil }
        var commands: [Command] = []
        var unrecognised: [String] = []
        for letter in letters {
            if let command = known[letter] {
                commands.append(command)
            } else {
                unrecognised.append(letter)
            }
        }
        return Explanation(commands: commands, unrecognised: unrecognised)
    }

    /// The single letters a prompt offers, in the order offered.
    private static func offeredLetters(in line: String) -> [String]? {
        let upper = line.uppercased()
        guard let range = upper.range(of: "ENTER COMMAND") else { return nil }
        // Everything after the prompt's colon is the offer list.
        let tail = upper[range.upperBound...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        let offer = tail[tail.index(after: colon)...]

        var letters: [String] = []
        for field in offer.split(separator: ",") {
            let token = field.trimmingCharacters(in: .whitespaces)
            // "or Help ?" closes the list and is not an offered command —
            // it is the node telling you how to ask it what these mean.
            guard token.count == 1, let scalar = token.first, scalar.isLetter else { continue }
            let letter = String(scalar)
            if !letters.contains(letter) { letters.append(letter) }
        }
        // No letters means this was some other software's "enter command".
        return letters.isEmpty ? nil : letters
    }
}

/// Decides when a KA-Node prompt is worth explaining.
///
/// Two quiet failure modes this exists to prevent. Explaining a prompt from a
/// station whose software is merely guessed at teaches a command set that
/// station may not have — the operator finds out by keying up. And explaining
/// on every prompt buries the transcript, because a node reprints its prompt
/// after every single command.
nonisolated struct KaNodePromptCoach: Sendable {

    private var explained: Set<String> = []

    init() {}

    /// The notice to show, or nil when there is nothing honest to say.
    ///
    /// `family` is the certainty gate: nil means AXTerm has not proven what
    /// this station runs, and a guess is worse than silence.
    mutating func notice(
        for line: String,
        peer: String,
        family: NodeSoftwareFamily?
    ) -> String? {
        guard family == .kaNode else { return nil }
        guard let explanation = KaNodeCommandHelp.explain(line) else { return nil }
        let key = CallsignValidator.normalize(peer)
        guard !key.isEmpty, !explained.contains(key) else { return nil }
        explained.insert(key)

        // Named as AXTerm's own words. This text never crossed the air, and
        // a transcript that blurs the two is a transcript you cannot trust.
        var lines = ["\(key) is a KA-Node. Its prompt offers:"]
        for command in explanation.commands {
            lines.append("  \(command.letter) — \(command.name): \(command.summary)")
        }
        if !explanation.unrecognised.isEmpty {
            lines.append("  \(explanation.unrecognised.joined(separator: ", ")) — "
                       + "offered by this node, but AXTerm does not know what it does.")
        }
        return lines.joined(separator: "\n")
    }

    /// Forget one station, so its next connection is explained afresh.
    mutating func forgetStation(_ peer: String) {
        explained.remove(CallsignValidator.normalize(peer))
    }
}
