import XCTest
@testable import AXTerm

/// Who actually said a line, during a relay.
///
/// Field case 2026-08-31. After the relay to BBSCBH established, COSCO's own
/// confirmation — `COSCO:KE0GB-7} Connected to BBSCBH:WG3K-4` — arrived on
/// DRLNOD's frames and was credited to BBSCBH, because the relay's
/// "who is expected to speak" is nil once the chain is up. The alias
/// harvester then filed "BBSCBH told us about COSCO", and BBSCBH — a
/// destination, a BBS, the end of the chain — appeared in the sidebar as a
/// node that reaches other nodes.
///
/// The fix is that the line names its own speaker. BPQ prefixes what it says
/// with `ALIAS:CALLSIGN}`, which is better evidence than anything inferred
/// from which link the bytes rode in on.
final class RelaySpeakerTests: XCTestCase {

    /// The line that caused it.
    func testABpqPromptPrefixNamesTheSpeaker() {
        XCTAssertEqual(
            RelaySpeaker.speaker(in: "COSCO:KE0GB-7} Connected to BBSCBH:WG3K-4"),
            "KE0GB-7")
        XCTAssertEqual(
            RelaySpeaker.speaker(in: "YZBBPQ:KB5YZB-7} Connected to COSCO:KE0GB-7"),
            "KB5YZB-7")
    }

    /// The callsign is what identifies a station; the alias is a name for it
    /// and may be shared or reused.
    func testTheCallsignIsPreferredOverTheAlias() {
        XCTAssertEqual(RelaySpeaker.speaker(in: "DRLBBS:KE0NCQ} Hello"), "KE0NCQ")
    }

    /// Most lines carry no such prefix, and guessing one would be worse than
    /// falling back to the link's own idea of who is talking.
    func testAPlainLineNamesNobody() {
        XCTAssertNil(RelaySpeaker.speaker(in: "###LINK MADE"))
        XCTAssertNil(RelaySpeaker.speaker(in: "Please enter your Name"))
        XCTAssertNil(RelaySpeaker.speaker(in: "de WG3K>"))
        XCTAssertNil(RelaySpeaker.speaker(in: ""))
    }

    /// A colon in prose is not a prompt prefix. Requiring the closing brace
    /// is what keeps ordinary text out.
    func testProseWithAColonIsNotAPrompt() {
        XCTAssertNil(RelaySpeaker.speaker(in: "ENTER COMMAND: B,C,J,N, or Help ?"))
        XCTAssertNil(RelaySpeaker.speaker(in: "Latest Message is 39649, Last listed is 0."))
        XCTAssertNil(RelaySpeaker.speaker(in: "HF-VHF Gateway: 145.050"))
    }

    /// Something shaped like a prompt but not carrying a callsign proves
    /// nothing, and must not become a station.
    func testAPromptWithoutARealCallsignNamesNobody() {
        XCTAssertNil(RelaySpeaker.speaker(in: "NOTACALL:ALSONOT} hello"))
        XCTAssertNil(RelaySpeaker.speaker(in: ":} hello"))
    }

    /// The prefix must be at the start. A callsign pair quoted mid-sentence
    /// is being talked *about*, not talking.
    func testAQuotedPairMidLineIsNotTheSpeaker() {
        XCTAssertNil(RelaySpeaker.speaker(
            in: "Connected to COSCO:KE0GB-7} by request"))
    }

    // MARK: - Choosing between the sources

    /// The whole point: a named speaker beats the relay's expectation and
    /// beats the link peer.
    func testANamedSpeakerWinsOverEverythingElse() {
        XCTAssertEqual(
            RelaySpeaker.attribute(line: "COSCO:KE0GB-7} Connected to BBSCBH:WG3K-4",
                                   relayWaitingOn: nil,
                                   linkPeer: "BBSCBH"),
            "KE0GB-7")
    }

    /// With no name in the line, the relay's own expectation is the next
    /// best evidence — it is what the app is waiting to hear from.
    func testTheRelayExpectationIsUsedWhenTheLineIsAnonymous() {
        XCTAssertEqual(
            RelaySpeaker.attribute(line: "###LINK MADE",
                                   relayWaitingOn: "KB5YZB-7",
                                   linkPeer: "DRLNOD"),
            "KB5YZB-7")
    }

    /// And with neither, the station whose frames these are.
    func testTheLinkPeerIsTheLastResort() {
        XCTAssertEqual(
            RelaySpeaker.attribute(line: "Please enter your Name",
                                   relayWaitingOn: nil,
                                   linkPeer: "DRLNOD"),
            "DRLNOD")
    }

    /// Regression for the reported case: BBSCBH must not be credited with
    /// COSCO's words simply because the chain had finished building.
    func testTheEstablishedDestinationIsNotCreditedWithMidChainChatter() {
        let speaker = RelaySpeaker.attribute(
            line: "COSCO:KE0GB-7} Connected to BBSCBH:WG3K-4",
            relayWaitingOn: nil,
            linkPeer: "BBSCBH")
        XCTAssertNotEqual(speaker, "BBSCBH")
    }
}
