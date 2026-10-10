import XCTest
@testable import AXTerm

/// The rules that keep a decoded APRS line short without losing anything.
final class ConsoleAPRSPresentationTests: XCTestCase {

    private func aprs(from: String = "N0AMY-6", to: String = "APRS", via: [String] = [],
                      info: String, radio: RadioID? = nil,
                      at time: Date = Date(timeIntervalSince1970: 1_000)) -> ConsoleLine {
        ConsoleLine.packet(from: from, to: to, text: info, timestamp: time, via: via,
                           radioID: radio, aprsInfo: Data(info.utf8))
    }

    private let position = "!3953.70N/10505.14W>Mobile"

    // MARK: Destination

    func testADecodedLineHidesItsDestination() {
        let line = aprs(to: "S8UQVU", info: position)
        XCTAssertNotNil(line.aprs)
        XCTAssertFalse(ConsoleAPRSPresentation.showsDestination(line, rawAPRS: false))
    }

    func testRawModeAndPlainPacketsKeepTheDestination() {
        XCTAssertTrue(ConsoleAPRSPresentation.showsDestination(aprs(info: position), rawAPRS: true))
        let session = ConsoleLine.packet(from: "N0CALL", to: "K0EPI-2", text: "Hello there")
        XCTAssertTrue(ConsoleAPRSPresentation.showsDestination(session, rawAPRS: false))
    }

    // MARK: Path chip

    func testUnusedPathMeansHeardDirect() {
        let line = aprs(via: ["WIDE1-1", "WIDE2-1"], info: position)
        XCTAssertEqual(ConsoleAPRSPresentation.pathChip(for: line, ownCallsigns: ["K0EPI-2"]),
                       .direct(requested: ["WIDE1-1", "WIDE2-1"]))
    }

    /// New-N: the fill-in digi inserts its call and marks WIDE1 used. The
    /// transmitter we heard is the station, not the alias.
    func testTheHeardStationIsTheLastRealDigipeater() {
        let line = aprs(via: ["W0NED*", "WIDE1*", "WIDE2-1"], info: position)
        XCTAssertEqual(ConsoleAPRSPresentation.pathChip(for: line, ownCallsigns: []),
                       .heardVia(station: "W0NED", hops: 1, path: ["W0NED*", "WIDE1*", "WIDE2-1"]))
    }

    func testHopsCountEveryStationThatRepeatedIt() {
        let line = aprs(via: ["WA6IFI-12*", "W0NED*", "WIDE2*"], info: position)
        guard case .heardVia(let station, let hops, _) =
                ConsoleAPRSPresentation.pathChip(for: line, ownCallsigns: []) else {
            return XCTFail("expected heardVia")
        }
        XCTAssertEqual(station, "W0NED")
        XCTAssertEqual(hops, 2)
    }

    func testAPathOfOnlyAliasesNamesTheAlias() {
        let line = aprs(via: ["WIDE2*"], info: position)
        XCTAssertEqual(ConsoleAPRSPresentation.pathChip(for: line, ownCallsigns: []),
                       .heardVia(station: "WIDE2", hops: 1, path: ["WIDE2*"]))
    }

    /// A gateway's own frame, marked used by itself, still came off its own
    /// transmitter.
    func testASenderMarkingItsOwnCallIsDirect() {
        let line = aprs(from: "W0NED", via: ["TCPIP*", "W0NED*"], info: position)
        XCTAssertEqual(ConsoleAPRSPresentation.pathChip(for: line, ownCallsigns: []),
                       .direct(requested: []))
    }

    func testOurOwnTransmissionHasNoChip() {
        let line = aprs(from: "K0EPI-2", via: ["WIDE1-1", "WIDE2-1"], info: position)
        XCTAssertEqual(ConsoleAPRSPresentation.pathChip(for: line, ownCallsigns: ["K0EPI-2"]), .none)
    }

    func testGenericAliases() {
        for alias in ["WIDE1-1", "WIDE2*", "WIDE", "TRACE3-3", "RELAY", "TCPIP*", "TCPXX", "qAR", "NOGATE", "RFONLY"] {
            XCTAssertTrue(ConsoleAPRSPresentation.isGenericAlias(alias), alias)
        }
        for station in ["W0NED", "WA6IFI-12*", "WIDEAWAKE", "K0EPI-2", "TRACEY"] {
            XCTAssertFalse(ConsoleAPRSPresentation.isGenericAlias(station), station)
        }
    }

    // MARK: Radio tags

    private let a705 = RadioID(rawValue: "a-705")
    private let bID50 = RadioID(rawValue: "b-id50")

    func testOneRadioInTheConsoleDrawsNoTags() {
        let names = [a705: "IC-705", bID50: "ID-50"]
        XCTAssertEqual(ConsoleRadioTags.tags(radioNames: names, heard: [a705]), [:])
    }

    func testTwoRadiosEachGetANameAndAColor() {
        let names = [a705: "IC-705", bID50: "ID-50"]
        let tags = ConsoleRadioTags.tags(radioNames: names, heard: [a705, bID50])
        XCTAssertEqual(tags[a705]?.name, "IC-705")
        XCTAssertEqual(tags[bID50]?.name, "ID-50")
        XCTAssertNotEqual(tags[a705]?.colorIndex, tags[bID50]?.colorIndex)
    }

    func testARadioKeepsItsColorWhenAThirdComesAndGoes() {
        let c = RadioID(rawValue: "c-other")
        let names = [a705: "IC-705", bID50: "ID-50", c: "Direwolf"]
        let two = ConsoleRadioTags.tags(radioNames: names, heard: [a705, bID50])
        let three = ConsoleRadioTags.tags(radioNames: names, heard: [a705, bID50, c])
        XCTAssertEqual(two[a705], three[a705])
        XCTAssertEqual(two[bID50], three[bID50])
    }

    // MARK: Row arrangement

    func testAMessageThatFitsStaysOnTheRow() {
        XCTAssertEqual(ConsoleRowArrangement.choose(leadingWidth: 300, messageWidth: 400,
                                                    available: 710, spacing: 6), .singleRow)
    }

    func testAMessageThatWouldWrapDropsBelow() {
        XCTAssertEqual(ConsoleRowArrangement.choose(leadingWidth: 300, messageWidth: 405,
                                                    available: 710, spacing: 6), .messageBelow)
    }

    // MARK: Mine

    private func mine(_ line: ConsoleLine) -> ConsoleMineHighlight {
        ConsoleMineHighlight.of(line, myCallsign: "K0EPI", ownCallsigns: ["K0EPI-2", "K0EPI-3"])
    }

    func testAMessageToAnyOfOurCallsIsForYou() {
        XCTAssertEqual(mine(aprs(from: "W0NED", info: ":K0EPI-7  :Hello{12")), .toYou)
        XCTAssertEqual(mine(aprs(from: "W0NED", info: ":K0EPI-3  :ack12")), .toYou)
    }

    func testOurBeaconHeardBackNamesTheDigi() {
        let line = aprs(from: "K0EPI-3", via: ["W0NED*", "WIDE1*", "WIDE2-1"], info: position)
        XCTAssertEqual(mine(line), .yourFrameRepeated(by: "W0NED"))
    }

    func testOurOwnFrameIsFromYou() {
        XCTAssertEqual(mine(aprs(from: "K0EPI-2", via: ["WIDE1-1"], info: position)), .fromYou)
        XCTAssertEqual(mine(aprs(from: "K0EPI-3", info: position)), .fromYou)
    }

    func testAFrameWeRepeatedIsRelayedByYou() {
        let line = aprs(from: "K0PWO", via: ["K0EPI-2*", "WIDE1*", "WIDE2-1"], info: position)
        XCTAssertEqual(mine(line), .relayedByYou)
    }

    func testOurCallInSomeoneElsesTextIsAMention() {
        XCTAssertEqual(mine(aprs(from: "W0NED", info: "!3953.70N/10505.14W>Hi K0EPI-3 73")), .mentionsYou)
        XCTAssertEqual(mine(aprs(from: "W0NED", info: "!3953.70N/10505.14W>K0EPIX is not us")), .none)
    }

    func testSessionLinesAreNeverHighlighted() {
        let session = ConsoleLine.packet(from: "N0CALL", to: "K0EPI-2", text: "Hello K0EPI")
        XCTAssertEqual(mine(session), .none)
    }

    // MARK: Repeat beacons

    private func group(_ line: ConsoleLine) -> ConsoleLineGroup { ConsoleLineGroup(primary: line) }

    func testTheSameBeaconAgainIsARepeat() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let lines = (0..<3).map { aprs(info: position, at: t0.addingTimeInterval(Double($0) * 60)) }
        let repeats = BeaconRepeatIndex().repeats(in: lines.map(group))
        XCTAssertNil(repeats[lines[0].id])
        XCTAssertEqual(repeats[lines[1].id], BeaconRepeat(ordinal: 2, since: t0))
        XCTAssertEqual(repeats[lines[2].id], BeaconRepeat(ordinal: 3, since: t0))
    }

    /// The same beacon heard again a second later off another digipeater is
    /// one transmission, not a repeat: it shared the count of the copy it
    /// duplicates instead of reading ×37 then ×38 (2026-10-10).
    func testCopiesInsideTheDuplicateWindowShareTheCount() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let times: [TimeInterval] = [0, 1, 60, 61]
        let lines = times.map { aprs(info: position, at: t0.addingTimeInterval($0)) }
        let repeats = BeaconRepeatIndex().repeats(in: lines.map(group))
        XCTAssertEqual(lines.map { repeats[$0.id]?.ordinal }, [nil, nil, 2, 2])
    }

    func testAChangeEndsTheRun() {
        let first = aprs(info: position)
        let moved = aprs(info: "!3953.80N/10505.14W>Mobile")
        let back = aprs(info: position)
        let repeats = BeaconRepeatIndex().repeats(in: [first, moved, back].map(group))
        XCTAssertTrue(repeats.isEmpty)
    }

    /// Another station's beacon in between does not break a run.
    func testRunsArePerStation() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a1 = aprs(from: "N0AMY-6", info: position, at: t0)
        let other = aprs(from: "W0NED", info: position, at: t0.addingTimeInterval(30))
        let a2 = aprs(from: "N0AMY-6", info: position, at: t0.addingTimeInterval(60))
        let repeats = BeaconRepeatIndex().repeats(in: [a1, other, a2].map(group))
        XCTAssertEqual(repeats[a2.id]?.ordinal, 2)
        XCTAssertNil(repeats[other.id])
    }

    func testMessagesAndSessionLinesNeverRepeat() {
        let m1 = aprs(from: "W0NED", info: ":K0EPI-2  :Hello{1")
        let m2 = aprs(from: "W0NED", info: ":K0EPI-2  :Hello{1")
        let s1 = ConsoleLine.packet(from: "N0CALL", to: "K0EPI-2", text: "Hello")
        let s2 = ConsoleLine.packet(from: "N0CALL", to: "K0EPI-2", text: "Hello")
        XCTAssertTrue(BeaconRepeatIndex().repeats(in: [m1, m2, s1, s2].map(group)).isEmpty)
    }

    // MARK: Unseen

    func testUnseenCountsWhatArrivedAfterTheLastSeenLine() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let lines = [
            aprs(info: position, at: t0),
            aprs(info: position, at: t0.addingTimeInterval(1)),
            aprs(from: "W0NED", info: ":K0EPI-2  :Hi{3", at: t0.addingTimeInterval(2)),
        ]
        let count = ConsoleUnseen.count(lines.map(group), after: t0) {
            ConsoleMineHighlight.of($0, myCallsign: "K0EPI", ownCallsigns: []) == .toYou
        }
        XCTAssertEqual(count, ConsoleUnseen.Count(total: 2, forYou: 1))
    }

    func testNothingIsUnseenWhileFollowing() {
        let lines = [aprs(info: position)]
        XCTAssertEqual(ConsoleUnseen.count(lines.map(group), after: nil) { _ in true }, ConsoleUnseen.Count())
    }

    // MARK: Coordinates

    func testTheTerminalDropsCoordinatesWhenItCanSayHowFar() {
        guard let digest = aprs(info: position).aprs else { return XCTFail("not decoded") }
        let home = GreatCircle.Point(latitude: 39.0, longitude: -104.8)
        let short = APRSDigestLine.text(for: digest, observer: home, coordinates: .whenNoDistance)
        XCTAssertFalse(short.contains("39.8950"), short)
        XCTAssertTrue(short.contains("mi"), short)
        let nowhere = APRSDigestLine.text(for: digest, observer: nil, coordinates: .whenNoDistance)
        XCTAssertTrue(nowhere.contains("39.8950"), nowhere)
        XCTAssertTrue(APRSDigestLine.text(for: digest, observer: home).contains("39.8950"))
    }

    // MARK: Mentions

    func testOurCallsignsAreFoundAsWholeWords() {
        let text = "To K0EPI-2: K0EPIX says hi to k0epi-3, not XK0EPI"
        let ranges = ConsoleAPRSPresentation.callsignRanges(in: text, bases: ["K0EPI"])
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["K0EPI-2", "k0epi-3"])
    }
}
