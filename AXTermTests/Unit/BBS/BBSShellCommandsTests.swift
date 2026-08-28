import XCTest
@testable import AXTerm

/// The commands added beyond the original six: the directory, the listings,
/// and the bulk forms.
final class BBSShellCommandsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func shell(caller: String = "K0XYZ",
                       sysop: String = "K0EPI-2",
                       heardList: Bool = true) -> BBSShell {
        BBSShell(caller: caller, sysop: sysop, calendar: utc, publishesHeardList: heardList)
    }

    private func message(_ id: Int64,
                         from: String = "W0ARP",
                         to: String = "K0XYZ",
                         subject: String = "Subject",
                         at: TimeInterval = 0,
                         readAt: Date? = nil) -> BBSMessage {
        BBSMessage(id: id, from: from, to: to, subject: subject, body: "Body",
                   receivedAt: t(at), readAt: readAt)
    }

    private func entry(_ callsign: String,
                       name: String? = nil,
                       homeBBS: String? = nil) -> WhitePagesEntry {
        var entry = WhitePagesEntry(callsign: callsign)
        if let name { entry.learn(.name, value: name, source: .selfReported, at: t(0)) }
        if let homeBBS { entry.learn(.homeBBS, value: homeBBS, source: .fromMessage, at: t(0)) }
        return entry
    }

    // MARK: - Identifying yourself

    func testNRecordsTheCallersName() {
        var sut = shell(caller: "K0XYZ-7")
        let out = sut.handle(line: "N Bob", mailbox: .init(), now: t(60))
        // Recorded against the base callsign: mail and identity belong to an
        // operator, not to whichever radio they called from.
        XCTAssertEqual(out.effects, [.learnWhitePages(
            callsign: "K0XYZ", key: .name, value: "Bob",
            source: .selfReported, at: t(60))])
    }

    func testNameKeepsItsSpacing() {
        var sut = shell()
        let out = sut.handle(line: "N Bob Smith", mailbox: .init(), now: t(60))
        guard case .learnWhitePages(_, _, let value, _, _)? = out.effects.first else {
            return XCTFail("expected a directory update")
        }
        XCTAssertEqual(value, "Bob Smith")
    }

    func testEachDirectoryFieldHasItsOwnCommand() {
        let cases: [(String, WhitePagesEntry.Key)] = [
            ("N Bob", .name), ("NQ Denver", .qth),
            ("NH K0NTS", .homeBBS), ("NZ 80202", .zip)
        ]
        for (line, key) in cases {
            var sut = shell()
            guard case .learnWhitePages(_, let actual, _, _, _)? =
                    sut.handle(line: line, mailbox: .init(), now: t(0)).effects.first else {
                return XCTFail("\(line) recorded nothing")
            }
            XCTAssertEqual(actual, key, "\(line) set the wrong field")
        }
    }

    func testBareFieldCommandShowsUsage() {
        var sut = shell()
        XCTAssertEqual(sut.handle(line: "N", mailbox: .init(), now: t(0)).lines,
                       ["Usage: N <name>"])
    }

    // MARK: - Looking people up

    func testInfoOnACallsignReportsTheirEntry() {
        var sut = shell()
        let box = BBSShell.Mailbox(whitePages: ["W0ARP": entry("W0ARP", name: "Bob")])
        let text = sut.handle(line: "I W0ARP", mailbox: box, now: t(0)).lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Bob"))
    }

    /// An SSID is a radio, not a person.
    func testLookupIsByBaseCallsign() {
        var sut = shell()
        let box = BBSShell.Mailbox(whitePages: ["W0ARP": entry("W0ARP", name: "Bob")])
        XCTAssertTrue(sut.handle(line: "I W0ARP-10", mailbox: box, now: t(0))
            .lines.joined().contains("Bob"))
    }

    func testUnknownCallsignSaysSo() {
        var sut = shell()
        XCTAssertEqual(sut.handle(line: "I W0ARP", mailbox: .init(), now: t(0)).lines,
                       ["Nothing on file for W0ARP."])
    }

    func testBareInfoDescribesThisStation() {
        var sut = shell(sysop: "K0EPI-2")
        let box = BBSShell.Mailbox(messages: [message(1)], nextID: 2,
                                   stationInfo: "Yaesu FT-991A, dipole at 10m.")
        let lines = sut.handle(line: "I", mailbox: box, now: t(0)).lines
        XCTAssertTrue(lines.contains { $0.contains("K0EPI-2") })
        XCTAssertTrue(lines.contains("Yaesu FT-991A, dipole at 10m."))
        XCTAssertTrue(lines.contains("1 message on file."))
    }

    func testDirectoryListing() {
        var sut = shell()
        let box = BBSShell.Mailbox(whitePages: [
            "W0ARP": entry("W0ARP", name: "Bob"),
            "K0NTS": entry("K0NTS", name: "Ann")
        ])
        let lines = sut.handle(line: "WP", mailbox: box, now: t(0)).lines
        XCTAssertTrue(lines[0].contains("CALL"))
        // Sorted, so a caller can find a callsign without reading every row.
        XCTAssertTrue(lines[1].hasPrefix("K0NTS"))
        XCTAssertTrue(lines[2].hasPrefix("W0ARP"))
    }

    func testEmptyDirectoryInvitesTheCallerToFillIt() {
        var sut = shell()
        XCTAssertTrue(sut.handle(line: "WP", mailbox: .init(), now: t(0))
            .lines[0].contains("N Your Name"))
    }

    // MARK: - Heard list

    func testHeardListsWhatThisStationHears() {
        var sut = shell()
        let box = BBSShell.Mailbox(heard: [
            .init(callsign: "W0ARP", lastHeard: t(0)),
            .init(callsign: "K0NTS", lastHeard: t(600))
        ])
        let lines = sut.handle(line: "J", mailbox: box, now: t(700)).lines
        // Newest first: the useful question is who is on now.
        XCTAssertTrue(lines[1].hasPrefix("K0NTS"))
        XCTAssertTrue(lines[2].hasPrefix("W0ARP"))
    }

    /// A heard list says what this antenna reaches, so the operator can decline.
    func testHeardListCanBeWithheld() {
        var sut = shell(heardList: false)
        let box = BBSShell.Mailbox(heard: [.init(callsign: "W0ARP", lastHeard: t(0))])
        let lines = sut.handle(line: "J", mailbox: box, now: t(0)).lines
        XCTAssertEqual(lines, ["The heard list is not published by this station."])
        XCTAssertFalse(lines.joined().contains("W0ARP"))
    }

    // MARK: - Listings

    func testListMineExcludesBulletins() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [
            message(1, to: "K0XYZ", subject: "Yours"),
            message(2, to: "ALL", subject: "Everyones")
        ], nextID: 3)
        let text = sut.handle(line: "LM", mailbox: box, now: t(0)).lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Yours"))
        XCTAssertFalse(text.contains("Everyones"))
    }

    func testListBulletinsExcludesPersonalMail() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [
            message(1, to: "K0XYZ", subject: "Yours"),
            message(2, to: "ALL", subject: "Everyones")
        ], nextID: 3)
        let text = sut.handle(line: "LB", mailbox: box, now: t(0)).lines.joined(separator: "\n")
        XCTAssertFalse(text.contains("Yours"))
        XCTAssertTrue(text.contains("Everyones"))
    }

    func testListLastNTakesTheNewest() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: (1...5).map {
            message(Int64($0), to: "ALL", subject: "Msg\($0)")
        }, nextID: 6)
        let text = sut.handle(line: "LL 2", mailbox: box, now: t(0)).lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Msg4"))
        XCTAssertTrue(text.contains("Msg5"))
        XCTAssertFalse(text.contains("Msg1"))
    }

    /// Never silently truncated — a listing that stops without saying so reads
    /// as "that is all there is".
    func testAnOverlongListingSaysWhatItLeftOut() {
        var sut = BBSShell(caller: "K0XYZ", sysop: "K0EPI", calendar: utc, maxListRows: 3)
        let box = BBSShell.Mailbox(messages: (1...10).map {
            message(Int64($0), to: "ALL")
        }, nextID: 11)
        let lines = sut.handle(line: "L", mailbox: box, now: t(0)).lines
        XCTAssertTrue(lines.last?.contains("7 older not shown") == true, lines.last ?? "")
    }

    // MARK: - Bulk read and kill

    func testReadMineReadsAndMarksEveryUnread() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [
            message(1, to: "K0XYZ"),
            message(2, to: "K0XYZ"),
            message(3, to: "K0XYZ", readAt: t(5))
        ], nextID: 4)
        let out = sut.handle(line: "RM", mailbox: box, now: t(60))
        XCTAssertEqual(out.effects, [.markRead(id: 1, at: t(60)), .markRead(id: 2, at: t(60))])
    }

    func testReadMineSaysSoWhenThereIsNothing() {
        var sut = shell()
        XCTAssertEqual(sut.handle(line: "RM", mailbox: .init(), now: t(0)).lines,
                       ["No unread mail for you."])
    }

    /// A caller who types KM before reading must not discover they destroyed
    /// something they never saw.
    func testKillMineSparesUnreadMail() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [
            message(1, to: "K0XYZ", readAt: t(5)),
            message(2, to: "K0XYZ")
        ], nextID: 3)
        let out = sut.handle(line: "KM", mailbox: box, now: t(60))
        XCTAssertEqual(out.effects, [.kill(id: 1, at: t(60))])
    }

    func testKillMineLeavesBulletinsAlone() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(
            messages: [message(1, to: "ALL", readAt: t(5))], nextID: 2)
        XCTAssertTrue(sut.handle(line: "KM", mailbox: box, now: t(60)).effects.isEmpty)
    }

    // MARK: - Posting

    func testSBAddressesEveryone() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(nextID: 1)
        let start = sut.handle(line: "SB", mailbox: box, now: t(0))
        XCTAssertTrue(start.lines[0].contains("every caller"))

        _ = sut.handle(line: "Net Tuesday", mailbox: box, now: t(1))
        _ = sut.handle(line: "2000 local.", mailbox: box, now: t(2))
        guard case .store(let posted)? =
                sut.handle(line: "/EX", mailbox: box, now: t(3)).effects.first else {
            return XCTFail("expected a stored bulletin")
        }
        XCTAssertEqual(posted.to, "ALL")
        XCTAssertTrue(posted.isBulletin)
    }

    /// `S CALL @ BBS` is where a home BBS comes from on a real network — and
    /// it is the sender describing somebody else, so it is inference.
    func testSendingViaAHomeBBSRecordsItAsInference() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(nextID: 1)
        _ = sut.handle(line: "S W0ARP @ K0NTS", mailbox: box, now: t(0))
        _ = sut.handle(line: "Subject", mailbox: box, now: t(1))
        _ = sut.handle(line: "Body", mailbox: box, now: t(2))
        let out = sut.handle(line: "/EX", mailbox: box, now: t(3))

        XCTAssertTrue(out.effects.contains(.learnWhitePages(
            callsign: "W0ARP", key: .homeBBS, value: "K0NTS",
            source: .fromMessage, at: t(3))))
    }

    // MARK: - Greeting

    func testGreetingUsesAKnownName() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(whitePages: ["K0XYZ": entry("K0XYZ", name: "Bob")])
        XCTAssertTrue(sut.greeting(mailbox: box, now: t(0)).lines.contains("Hello Bob."))
    }

    // MARK: - First-call registration

    /// How the directory actually fills up: ask once, while they are there.
    /// FBB walks a first-time caller through the same fields.
    func testFirstCallStartsRegistration() {
        var sut = shell(caller: "K0XYZ")
        let out = sut.greeting(mailbox: .init(), now: t(0))
        XCTAssertTrue(out.lines.contains { $0.contains("Your name") }, out.lines.joined())
        // No prompt: the caller is being asked a question, not offered a menu.
        XCTAssertNil(out.prompt)
    }

    func testRegistrationWalksThePublicFieldsAndStores() {
        var sut = shell(caller: "K0XYZ")
        _ = sut.greeting(mailbox: .init(), now: t(0))

        var effects: [BBSShell.Effect] = []
        for answer in ["Bob", "Denver, CO", "80202", "K0NTS"] {
            effects += sut.handle(line: answer, mailbox: .init(), now: t(1)).effects
        }
        XCTAssertEqual(effects, [
            .learnWhitePages(callsign: "K0XYZ", key: .name, value: "Bob",
                             source: .selfReported, at: t(1)),
            .learnWhitePages(callsign: "K0XYZ", key: .qth, value: "Denver, CO",
                             source: .selfReported, at: t(1)),
            .learnWhitePages(callsign: "K0XYZ", key: .zip, value: "80202",
                             source: .selfReported, at: t(1)),
            .learnWhitePages(callsign: "K0XYZ", key: .homeBBS, value: "K0NTS",
                             source: .selfReported, at: t(1))
        ])
        // And they land at the prompt afterwards.
        XCTAssertTrue(sut.handle(line: "V", mailbox: .init(), now: t(2)).lines
            .contains(BBSShell.version))
    }

    func testBlankAnswersSkipWithoutStoringAnything() {
        var sut = shell(caller: "K0XYZ")
        _ = sut.greeting(mailbox: .init(), now: t(0))
        var effects: [BBSShell.Effect] = []
        for _ in 0..<4 {
            effects += sut.handle(line: "", mailbox: .init(), now: t(1)).effects
        }
        XCTAssertTrue(effects.isEmpty)
    }

    /// A caller who did not want to be interviewed should not have to press
    /// Return four times to escape.
    func testAbortLeavesRegistrationAtOnce() {
        var sut = shell(caller: "K0XYZ")
        _ = sut.greeting(mailbox: .init(), now: t(0))
        let out = sut.handle(line: "A", mailbox: .init(), now: t(1))
        XCTAssertTrue(out.effects.isEmpty)
        XCTAssertTrue(out.lines.contains { $0.contains("H = help") }, out.lines.joined())
    }

    func testAKnownCallerIsNotInterviewedAgain() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(whitePages: ["K0XYZ": entry("K0XYZ", name: "Bob")])
        let out = sut.greeting(mailbox: box, now: t(0))
        XCTAssertFalse(out.lines.contains { $0.contains("Your name") })
        XCTAssertEqual(out.prompt, ">")
    }

    // MARK: - What is not collected

    /// Packet is unencrypted broadcast, so a mailbox that offers to store a
    /// home address is inviting people to put one on the air. A field that is
    /// never asked for cannot be leaked.
    func testThereIsNoWayToStoreAddressPhoneOrEmail() {
        XCTAssertEqual(Set(WhitePagesEntry.Key.allCases),
                       [.name, .qth, .zip, .homeBBS])

        for line in ["NA 12 Elm St", "NP 555-0100", "NE bob@example.com"] {
            var sut = shell()
            let out = sut.handle(line: line, mailbox: .init(), now: t(0))
            XCTAssertTrue(out.effects.isEmpty, "\(line) stored something")
            XCTAssertTrue(out.lines.first?.contains("H = help") == true,
                          "\(line) should read as an unknown command")
        }
    }

    /// And registration asks for the four and stops.
    func testRegistrationAsksOnlyTheFour() {
        XCTAssertEqual(WhitePagesEntry.Key.registration, [.name, .qth, .zip, .homeBBS])
    }

    // MARK: - Misc

    /// `V` is the file viewer; version moved to `VER`. `V` for "view" is the
    /// convention on every mailbox that has a file area, and a caller reaching
    /// for it wants the file, not a banner.
    func testVersionAnswers() {
        var sut = shell()
        XCTAssertEqual(sut.handle(line: "V", mailbox: .init(), now: t(0)).lines,
                       [BBSShell.version])
    }

    func testHelpCoversEveryCommandItAdvertises() {
        var sut = shell()
        let help = sut.handle(line: "H", mailbox: .init(), now: t(0)).lines.joined(separator: "\n")
        for command in ["LM", "LL", "RM", "SB", "KM", "I CALL", "WP", "J", "N name", "NH", "NQ", "NZ", "V", "W", "WN", "D <name>", "U", "A"] {
            XCTAssertTrue(help.contains(command), "help does not mention \(command)")
        }
    }
}
