import XCTest
@testable import AXTerm

/// The personal mailbox command shell.
///
/// Weighted deliberately toward the visibility rules. Getting `L` to line up
/// costs an afternoon; letting a caller read the sysop's mail costs the
/// operator's trust in the whole feature, so most of what follows is about
/// what a caller must *not* be able to see, name, or enumerate.
final class BBSShellTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // 14 Nov 2023 UTC
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func shell(caller: String = "K0XYZ",
                       sysop: String = "K0EPI-2",
                       banner: String = "") -> BBSShell {
        BBSShell(caller: caller, sysop: sysop, banner: banner, calendar: utc)
    }

    private func message(_ id: Int64,
                         from: String = "W0ARP",
                         to: String = "K0XYZ",
                         subject: String = "Test",
                         body: String = "Body",
                         at: TimeInterval = 0,
                         readAt: Date? = nil,
                         killedAt: Date? = nil) -> BBSMessage {
        BBSMessage(id: id, from: from, to: to, subject: subject, body: body,
                   receivedAt: t(at), readAt: readAt, killedAt: killedAt)
    }

    // MARK: - Visibility

    func testCallerReadsMailAddressedToThem() {
        var sut = shell()
        let box = BBSShell.Mailbox(messages: [message(1, to: "K0XYZ", body: "Hello")], nextID: 2)
        let out = sut.handle(line: "R 1", mailbox: box, now: t(60))
        XCTAssertTrue(out.lines.contains("Hello"))
    }

    func testCallerReadsBulletins() {
        var sut = shell()
        let box = BBSShell.Mailbox(messages: [message(1, to: "ALL", body: "Net Tuesday")], nextID: 2)
        let out = sut.handle(line: "R 1", mailbox: box, now: t(60))
        XCTAssertTrue(out.lines.contains("Net Tuesday"))
    }

    /// The one that matters.
    func testCallerCannotReadSomeoneElsesMail() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [message(1, to: "K0EPI", body: "Private")], nextID: 2)
        let out = sut.handle(line: "R 1", mailbox: box, now: t(60))
        XCTAssertFalse(out.lines.contains("Private"))
        XCTAssertEqual(out.lines, ["Message 1 not found."])
    }

    /// A caller must not be able to tell "not yours" from "does not exist", or
    /// they can map the sysop's mailbox one number at a time.
    func testPrivateMailIsIndistinguishableFromAbsentMail() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [message(1, to: "K0EPI")], nextID: 2)

        var other = shell(caller: "K0XYZ")
        let empty = BBSShell.Mailbox(messages: [], nextID: 2)

        XCTAssertEqual(sut.handle(line: "R 1", mailbox: box, now: t(60)).lines,
                       other.handle(line: "R 1", mailbox: empty, now: t(60)).lines)
    }

    func testListOmitsMailForOtherStations() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [
            message(1, to: "K0XYZ", subject: "Yours"),
            message(2, to: "K0EPI", subject: "Theirs"),
            message(3, to: "ALL", subject: "Everyones")
        ], nextID: 4)
        let text = sut.handle(line: "L", mailbox: box, now: t(60)).lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Yours"))
        XCTAssertTrue(text.contains("Everyones"))
        XCTAssertFalse(text.contains("Theirs"))
    }

    func testKilledMessagesAreInvisible() {
        var sut = shell()
        let box = BBSShell.Mailbox(
            messages: [message(1, to: "K0XYZ", subject: "Gone", killedAt: t(5))], nextID: 2)
        XCTAssertEqual(sut.handle(line: "L", mailbox: box, now: t(60)).lines, ["No messages."])
    }

    /// Mail is addressed to an operator, not to a radio.
    func testCallerCollectsMailAddressedToTheirBaseCallsign() {
        var sut = shell(caller: "K0XYZ-7")
        let box = BBSShell.Mailbox(messages: [message(1, to: "K0XYZ", body: "Reachable")], nextID: 2)
        XCTAssertTrue(sut.handle(line: "R 1", mailbox: box, now: t(60)).lines.contains("Reachable"))
    }

    func testDifferentCallsignIsADifferentOperator() {
        var sut = shell(caller: "K0XYZA")
        let box = BBSShell.Mailbox(messages: [message(1, to: "K0XYZ")], nextID: 2)
        XCTAssertEqual(sut.handle(line: "R 1", mailbox: box, now: t(60)).lines,
                       ["Message 1 not found."])
    }

    // MARK: - Kill

    func testCallerKillsMailAddressedToThem() {
        var sut = shell()
        let box = BBSShell.Mailbox(messages: [message(1, to: "K0XYZ")], nextID: 2)
        let out = sut.handle(line: "K 1", mailbox: box, now: t(60))
        XCTAssertEqual(out.effects, [.kill(id: 1, at: t(60))])
    }

    func testCallerKillsTheirOwnBulletin() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [message(1, from: "K0XYZ", to: "ALL")], nextID: 2)
        XCTAssertEqual(sut.handle(line: "K 1", mailbox: box, now: t(60)).effects,
                       [.kill(id: 1, at: t(60))])
    }

    /// Otherwise any caller can quietly remove a notice meant for everybody.
    func testCallerCannotKillSomeoneElsesBulletin() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [message(1, from: "W0ARP", to: "ALL")], nextID: 2)
        let out = sut.handle(line: "K 1", mailbox: box, now: t(60))
        XCTAssertTrue(out.effects.isEmpty)
        XCTAssertEqual(out.lines, ["Message 1 is not yours to kill."])
    }

    func testKillingInvisibleMailReportsNotFound() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [message(1, to: "K0EPI")], nextID: 2)
        let out = sut.handle(line: "K 1", mailbox: box, now: t(60))
        XCTAssertTrue(out.effects.isEmpty)
        XCTAssertEqual(out.lines, ["Message 1 not found."])
    }

    // MARK: - Read flags

    func testReadingPersonalMailMarksItRead() {
        var sut = shell()
        let box = BBSShell.Mailbox(messages: [message(1, to: "K0XYZ")], nextID: 2)
        XCTAssertEqual(sut.handle(line: "R 1", mailbox: box, now: t(60)).effects,
                       [.markRead(id: 1, at: t(60))])
    }

    /// One flag cannot describe many readers, so a bulletin never carries one.
    func testReadingABulletinDoesNotMarkItRead() {
        var sut = shell()
        let box = BBSShell.Mailbox(messages: [message(1, to: "ALL")], nextID: 2)
        XCTAssertTrue(sut.handle(line: "R 1", mailbox: box, now: t(60)).effects.isEmpty)
    }

    func testAlreadyReadMailIsNotMarkedAgain() {
        var sut = shell()
        let box = BBSShell.Mailbox(
            messages: [message(1, to: "K0XYZ", readAt: t(5))], nextID: 2)
        XCTAssertTrue(sut.handle(line: "R 1", mailbox: box, now: t(60)).effects.isEmpty)
    }

    // MARK: - Greeting

    func testGreetingCountsOnlyUnreadPersonalMail() {
        var sut = shell()
        let box = BBSShell.Mailbox(messages: [
            message(1, to: "K0XYZ"),
            message(2, to: "K0XYZ", readAt: t(5)),
            message(3, to: "ALL"),
            message(4, to: "K0EPI")
        ], nextID: 5)
        XCTAssertTrue(sut.greeting(mailbox: box, now: t(60)).lines.contains("1 message for you."))
    }

    func testGreetingSaysSoWhenThereIsNothing() {
        var sut = shell()
        XCTAssertTrue(sut.greeting(mailbox: BBSShell.Mailbox(), now: t(60))
            .lines.contains("No new messages for you."))
    }

    /// The operator's own words, carried verbatim — this is where hours live.
    func testGreetingCarriesTheOperatorsBanner() {
        var sut = shell(banner: "Evenings, US Central.")
        XCTAssertTrue(sut.greeting(mailbox: BBSShell.Mailbox(), now: t(60))
            .lines.contains("Evenings, US Central."))
    }

    // MARK: - Sending

    func testSendStoresTheMessage() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [], nextID: 12)

        XCTAssertEqual(sut.handle(line: "S K0EPI", mailbox: box, now: t(0)).lines, ["Subj:"])
        _ = sut.handle(line: "Antenna party", mailbox: box, now: t(1))
        _ = sut.handle(line: "Count me in.", mailbox: box, now: t(2))
        _ = sut.handle(line: "Bringing rope.", mailbox: box, now: t(3))
        let out = sut.handle(line: "/EX", mailbox: box, now: t(4))

        XCTAssertEqual(out.lines, ["Message 12 stored."])
        XCTAssertEqual(out.effects, [.store(BBSMessage(
            id: 12, from: "K0XYZ", to: "K0EPI", subject: "Antenna party",
            body: "Count me in.\nBringing rope.", receivedAt: t(4)))])
    }

    /// `S` with no argument is the common case on a personal mailbox: the
    /// caller wants to leave a note for whoever owns it.
    func testSendWithNoArgumentAddressesTheSysop() {
        var sut = shell(caller: "K0XYZ", sysop: "K0EPI-2")
        let box = BBSShell.Mailbox(nextID: 1)
        _ = sut.handle(line: "S", mailbox: box, now: t(0))
        _ = sut.handle(line: "Hi", mailbox: box, now: t(1))
        let out = sut.handle(line: "/EX", mailbox: box, now: t(2))
        guard case .store(let stored)? = out.effects.first else {
            return XCTFail("expected a stored message")
        }
        XCTAssertEqual(stored.to, "K0EPI-2")
    }

    func testCtrlZAlsoEndsAMessage() {
        var sut = shell()
        let box = BBSShell.Mailbox(nextID: 1)
        _ = sut.handle(line: "S K0EPI", mailbox: box, now: t(0))
        _ = sut.handle(line: "Subject", mailbox: box, now: t(1))
        _ = sut.handle(line: "Body", mailbox: box, now: t(2))
        let out = sut.handle(line: "\u{1A}", mailbox: box, now: t(3))
        XCTAssertEqual(out.lines, ["Message 1 stored."])
    }

    func testEmptySubjectBecomesNone() {
        var sut = shell()
        let box = BBSShell.Mailbox(nextID: 1)
        _ = sut.handle(line: "S K0EPI", mailbox: box, now: t(0))
        _ = sut.handle(line: "", mailbox: box, now: t(1))
        _ = sut.handle(line: "Body", mailbox: box, now: t(2))
        let out = sut.handle(line: "/EX", mailbox: box, now: t(3))
        guard case .store(let stored)? = out.effects.first else {
            return XCTFail("expected a stored message")
        }
        XCTAssertEqual(stored.subject, "(none)")
    }

    /// A command typed while composing is text, not a command — otherwise a
    /// message whose body contains "B" on a line by itself hangs up the call.
    func testCommandsAreInertWhileComposing() {
        var sut = shell()
        let box = BBSShell.Mailbox(nextID: 1)
        _ = sut.handle(line: "S K0EPI", mailbox: box, now: t(0))
        _ = sut.handle(line: "Subject", mailbox: box, now: t(1))

        let mid = sut.handle(line: "B", mailbox: box, now: t(2))
        XCTAssertTrue(mid.effects.isEmpty, "B while composing must not disconnect")

        let out = sut.handle(line: "/EX", mailbox: box, now: t(3))
        guard case .store(let stored)? = out.effects.first else {
            return XCTFail("expected a stored message")
        }
        XCTAssertEqual(stored.body, "B")
    }

    /// Refused, not truncated: a caller whose message was silently halved
    /// believes it arrived whole.
    func testOverlongMessageIsRefusedAndStoresNothing() {
        var sut = BBSShell(caller: "K0XYZ", sysop: "K0EPI", calendar: utc, maxBodyLines: 3)
        let box = BBSShell.Mailbox(nextID: 1)
        _ = sut.handle(line: "S K0EPI", mailbox: box, now: t(0))
        _ = sut.handle(line: "Subject", mailbox: box, now: t(1))
        for i in 0..<3 { _ = sut.handle(line: "line \(i)", mailbox: box, now: t(2)) }
        let out = sut.handle(line: "one too many", mailbox: box, now: t(3))

        XCTAssertTrue(out.effects.isEmpty)
        XCTAssertTrue(out.lines.first?.contains("too long") == true)
        // And the caller is back at the prompt, not stuck mid-message.
        XCTAssertEqual(sut.handle(line: "L", mailbox: box, now: t(4)).lines, ["No messages."])
    }

    // MARK: - Session

    func testByeDisconnects() {
        var sut = shell()
        let out = sut.handle(line: "B", mailbox: BBSShell.Mailbox(), now: t(60))
        XCTAssertEqual(out.effects, [.disconnect])
        XCTAssertNil(out.prompt)
    }

    func testNothingIsAnsweredAfterGoodbye() {
        var sut = shell()
        _ = sut.handle(line: "B", mailbox: BBSShell.Mailbox(), now: t(60))
        let out = sut.handle(line: "L", mailbox: BBSShell.Mailbox(), now: t(61))
        XCTAssertTrue(out.lines.isEmpty)
        XCTAssertTrue(out.effects.isEmpty)
    }

    func testUnknownCommandNamesTheAlternatives() {
        var sut = shell()
        let out = sut.handle(line: "XYZZY", mailbox: BBSShell.Mailbox(), now: t(60))
        XCTAssertTrue(out.lines.first?.contains("H = help") == true)
    }

    func testBlankLineJustReprompts() {
        var sut = shell()
        let out = sut.handle(line: "   ", mailbox: BBSShell.Mailbox(), now: t(60))
        XCTAssertTrue(out.lines.isEmpty)
        XCTAssertEqual(out.prompt, ">")
    }

    func testCommandsAreCaseInsensitive() {
        var sut = shell()
        let box = BBSShell.Mailbox(messages: [message(1, to: "K0XYZ", subject: "Hi")], nextID: 2)
        XCTAssertEqual(sut.handle(line: "l", mailbox: box, now: t(60)).lines,
                       sut.handle(line: "L", mailbox: box, now: t(60)).lines)
    }

    // MARK: - Listing

    func testListIsOrderedByNumberAndFlagsUnreadPersonalMail() {
        var sut = shell(caller: "K0XYZ")
        let box = BBSShell.Mailbox(messages: [
            message(11, from: "W0ARP", to: "K0XYZ", subject: "Antenna party"),
            message(7, from: "K0NTS", to: "ALL", subject: "Net moving to 145.030")
        ], nextID: 12)
        let lines = sut.handle(line: "L", mailbox: box, now: t(60)).lines

        XCTAssertEqual(lines.first, "  #  DATE   FROM     TO     SUBJECT")
        XCTAssertTrue(lines[1].hasPrefix("  7 "))   // bulletin, unflagged
        XCTAssertTrue(lines[2].hasPrefix(" 11*"))   // unread, addressed to caller
        XCTAssertTrue(lines[1].contains("11/14"))
    }

    func testLongSubjectsAreTruncatedRatherThanWrapped() {
        var sut = shell()
        let box = BBSShell.Mailbox(
            messages: [message(1, to: "K0XYZ", subject: String(repeating: "x", count: 80))],
            nextID: 2)
        let row = sut.handle(line: "L", mailbox: box, now: t(60)).lines[1]
        XCTAssertLessThan(row.count, 78)
    }

    func testUsageIsShownForMalformedArguments() {
        var sut = shell()
        XCTAssertEqual(sut.handle(line: "R", mailbox: BBSShell.Mailbox(), now: t(60)).lines,
                       ["Usage: R n"])
        XCTAssertEqual(sut.handle(line: "K x", mailbox: BBSShell.Mailbox(), now: t(60)).lines,
                       ["Usage: K n"])
    }
}
