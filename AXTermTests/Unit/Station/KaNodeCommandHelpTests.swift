import XCTest
@testable import AXTerm

/// Explaining a KA-Node's command prompt in the operator's own terminal.
///
/// The node states its command set and nothing else: `ENTER COMMAND: B,C,J,N,
/// or Help ?`. Four letters, no hint as to what any of them do, and the one
/// that would tell you costs airtime on a shared channel to ask.
///
/// The rule this type exists to keep: explain the letters *this* node
/// offered, and only those. A canned Kantronics command list would describe
/// commands a given node may not have, which is worse than silence — the
/// operator would key up and get an error, on the air, for a command AXTerm
/// invented.
final class KaNodeCommandHelpTests: XCTestCase {

    /// The prompt from DRLNOD (KE0NCQ), verbatim.
    private let drlnod = "ENTER COMMAND: B,C,J,N, or Help ?"

    func testRecognisesTheKantronicsPrompt() {
        XCTAssertTrue(KaNodeCommandHelp.isCommandPrompt(drlnod))
        XCTAssertTrue(KaNodeCommandHelp.isCommandPrompt("ENTER COMMAND: B,C,J,N, or Help ?"))
    }

    /// A BPQ prompt is a different shape and a different command set. Reading
    /// one as Kantronics would explain commands that do not exist there.
    func testDoesNotClaimOtherSoftwaresPrompts() {
        XCTAssertFalse(KaNodeCommandHelp.isCommandPrompt("YZBBPQ:KB5YZB-7} "))
        XCTAssertFalse(KaNodeCommandHelp.isCommandPrompt("de WG3K>"))
        XCTAssertFalse(KaNodeCommandHelp.isCommandPrompt("Commands:"))
        XCTAssertFalse(KaNodeCommandHelp.isCommandPrompt(""))
    }

    func testExplainsExactlyTheLettersOffered() throws {
        let help = try XCTUnwrap(KaNodeCommandHelp.explain(drlnod))
        XCTAssertEqual(help.commands.map(\.letter), ["B", "C", "J", "N"])
        XCTAssertTrue(help.unrecognised.isEmpty)
    }

    /// The question that prompted this: on a KA-Node, what is J versus N?
    /// One is a measurement, the other a directory, and conflating them is
    /// how second-hand names get treated as heard-here RF.
    func testJIsAMeasurementAndNIsADirectory() throws {
        let help = try XCTUnwrap(KaNodeCommandHelp.explain(drlnod))
        let j = try XCTUnwrap(help.commands.first { $0.letter == "J" })
        let n = try XCTUnwrap(help.commands.first { $0.letter == "N" })

        XCTAssertEqual(j.name, "JHeard")
        XCTAssertTrue(j.summary.lowercased().contains("heard"), j.summary)
        XCTAssertTrue(j.summary.lowercased().contains("direct"), j.summary)

        XCTAssertEqual(n.name, "Nodes")
        XCTAssertTrue(n.summary.lowercased().contains("know"), n.summary)
        XCTAssertNotEqual(j.summary, n.summary)
    }

    /// Connect is the one that spends airtime on someone else's behalf, so
    /// it says what it actually does rather than just naming itself.
    func testConnectSaysItRelays() throws {
        let help = try XCTUnwrap(KaNodeCommandHelp.explain(drlnod))
        let c = try XCTUnwrap(help.commands.first { $0.letter == "C" })
        XCTAssertTrue(c.summary.contains("C "), "should show the usage: \(c.summary)")
    }

    /// A node offering a smaller set gets a smaller explanation. Describing
    /// J to a node that does not offer J invites an error on the air.
    func testANarrowerPromptGetsANarrowerExplanation() throws {
        let help = try XCTUnwrap(KaNodeCommandHelp.explain("ENTER COMMAND: B,C, or Help ?"))
        XCTAssertEqual(help.commands.map(\.letter), ["B", "C"])
    }

    /// A letter AXTerm does not know is reported as unknown rather than
    /// guessed at. Inventing a meaning is the failure mode this guards.
    func testAnUnknownLetterIsAdmittedNotInvented() throws {
        let help = try XCTUnwrap(KaNodeCommandHelp.explain("ENTER COMMAND: B,C,Q,Z, or Help ?"))
        XCTAssertEqual(help.commands.map(\.letter), ["B", "C"])
        XCTAssertEqual(help.unrecognised, ["Q", "Z"])
    }

    /// Nothing to explain about a line that is not a prompt.
    func testNonPromptsExplainNothing() {
        XCTAssertNil(KaNodeCommandHelp.explain("###LINK MADE"))
        XCTAssertNil(KaNodeCommandHelp.explain("Welcome to COSCO:KE0GB-7 Network Node"))
    }
}

/// Deciding *when* to explain a prompt.
///
/// Two ways this goes wrong quietly. Explaining a prompt from a station whose
/// software is only guessed at teaches the operator a command set that
/// station may not have; and explaining on every prompt buries the session
/// transcript under the same paragraph, because a node reprints its prompt
/// after every command.
final class KaNodePromptCoachTests: XCTestCase {

    private let prompt = "ENTER COMMAND: B,C,J,N, or Help ?"

    func testExplainsAProvenKaNodeOnce() {
        var coach = KaNodePromptCoach()
        let first = coach.notice(for: prompt, peer: "DRLNOD", family: .kaNode)
        XCTAssertNotNil(first)
        XCTAssertTrue(first?.contains("JHeard") ?? false)

        XCTAssertNil(coach.notice(for: prompt, peer: "DRLNOD", family: .kaNode),
                     "a node reprints its prompt after every command")
    }

    /// Certainty is the whole gate. An unidentified station gets nothing —
    /// silence is correct, a guessed command set is not.
    func testSaysNothingWhenTheSoftwareIsNotProven() {
        var coach = KaNodePromptCoach()
        XCTAssertNil(coach.notice(for: prompt, peer: "DRLNOD", family: nil))
        XCTAssertNil(coach.notice(for: prompt, peer: "KB5YZB-7", family: .bpq))
        XCTAssertNil(coach.notice(for: prompt, peer: "COSCO", family: .netromOther))
    }

    /// Having explained one node says nothing about the next.
    func testEachStationIsExplainedOnItsOwn() {
        var coach = KaNodePromptCoach()
        XCTAssertNotNil(coach.notice(for: prompt, peer: "DRLNOD", family: .kaNode))
        XCTAssertNotNil(coach.notice(for: prompt, peer: "EATON", family: .kaNode))
    }

    /// A fresh connection is a fresh chance to be useful — the operator may
    /// well have forgotten, and the node may offer a different set.
    func testANewConnectionExplainsAgain() {
        var coach = KaNodePromptCoach()
        XCTAssertNotNil(coach.notice(for: prompt, peer: "DRLNOD", family: .kaNode))
        coach.forgetStation("DRLNOD")
        XCTAssertNotNil(coach.notice(for: prompt, peer: "DRLNOD", family: .kaNode))
    }

    func testOrdinaryTrafficIsNotAPrompt() {
        var coach = KaNodePromptCoach()
        XCTAssertNil(coach.notice(for: "###LINK MADE", peer: "DRLNOD", family: .kaNode))
    }

    /// The notice must read as AXTerm's own words. Presenting it as though
    /// the node said it would put text on the operator's transcript that
    /// never crossed the air.
    func testTheNoticeIsMarkedAsOurs() throws {
        var coach = KaNodePromptCoach()
        let notice = try XCTUnwrap(coach.notice(for: prompt, peer: "DRLNOD", family: .kaNode))
        XCTAssertTrue(notice.hasPrefix("DRLNOD is a KA-Node"), notice)
    }

    /// A node offering something we cannot explain says so, rather than
    /// leaving the operator to assume the list was complete.
    func testUnknownLettersAreNamedInTheNotice() throws {
        var coach = KaNodePromptCoach()
        let notice = try XCTUnwrap(coach.notice(
            for: "ENTER COMMAND: B,C,Z, or Help ?", peer: "DRLNOD", family: .kaNode))
        XCTAssertTrue(notice.contains("Z"), notice)
    }
}
