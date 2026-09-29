import XCTest
@testable import AXTerm

/// Browsing and fetching files at the prompt.
///
/// The theme throughout: on a link this slow, the expensive mistake is
/// starting a transfer nobody wanted. Most of what follows is about telling a
/// caller what something costs *before* they commit to it.
final class BBSFileCommandsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 90 B/s is the shipped default — a realistic 1200-baud channel.
    private func shell(bytesPerSecond: Double = 90) -> BBSShell {
        BBSShell(caller: "K0XYZ", sysop: "K0EPI-2", calendar: utc,
                 bytesPerSecond: bytesPerSecond)
    }

    private func file(_ name: String,
                      area: String = "OPS",
                      bytes: Int = 2_048,
                      about: String = "",
                      modified: TimeInterval = 0) -> BBSSharedFile {
        BBSSharedFile(area: area, name: name, byteCount: bytes,
                      modifiedAt: t(modified), about: about)
    }

    private func mailbox(_ files: [BBSSharedFile],
                         areas: [BBSFileArea]? = nil,
                         lastVisit: Date? = nil) -> BBSShell.Mailbox {
        let resolved = areas ?? Set(files.map(\.area)).map { BBSFileArea(name: $0) }
        return BBSShell.Mailbox(files: BBSFileIndex(areas: resolved, files: files),
                                lastVisit: lastVisit)
    }

    // MARK: - Browsing

    func testNoFilesSaysSo() {
        var sut = shell()
        XCTAssertEqual(sut.handle(line: "F", mailbox: .init(), now: t(0)).lines,
                       ["No files are shared here."])
    }

    func testAreaListingCountsAndSizes() {
        var sut = shell()
        let box = mailbox([file("a.txt", bytes: 1_024), file("b.txt", bytes: 3_072)],
                          areas: [BBSFileArea(name: "OPS", about: "Net scripts")])
        let lines = sut.handle(line: "F", mailbox: box, now: t(0)).lines
        XCTAssertTrue(lines[0].contains("AREA"))
        XCTAssertTrue(lines[1].contains("OPS"))
        XCTAssertTrue(lines[1].contains("2"), lines[1])
        XCTAssertTrue(lines[1].contains("4K"), lines[1])
        XCTAssertTrue(lines[1].contains("Net scripts"))
        // The listing has to teach the next command, or a caller who cannot
        // see a screen has no way to find one.
        XCTAssertTrue(lines.last?.contains("WN") == true)
    }

    /// The whole point of the TIME column.
    func testFileListingQuotesAirtimeNotJustBytes() {
        var sut = shell()
        let box = mailbox([file("roster.txt", bytes: 146_432, about: "Duty roster")])
        let lines = sut.handle(line: "F OPS", mailbox: box, now: t(0)).lines
        let row = try! XCTUnwrap(lines.first { $0.contains("roster.txt") })
        XCTAssertTrue(row.contains("143K"), row)
        XCTAssertTrue(row.contains("28m"), row)
        XCTAssertTrue(row.contains("Duty roster"), row)
    }

    func testUnknownAreaPointsBackAtTheAreaList() {
        var sut = shell()
        let box = mailbox([file("a.txt")])
        XCTAssertEqual(sut.handle(line: "F NOPE", mailbox: box, now: t(0)).lines,
                       ["No area called NOPE. W lists the areas."])
    }

    func testAreaNamesAreTypedLoosely() {
        var sut = shell()
        let box = mailbox([file("a.txt", area: "OPS")])
        XCTAssertTrue(sut.handle(line: "F ops", mailbox: box, now: t(0))
            .lines.contains { $0.contains("a.txt") })
    }

    // MARK: - What is new

    /// The question a regular caller actually has. Sending the whole catalogue
    /// every visit spends airtime telling them what they already know.
    func testNewListsOnlyWhatChangedSinceTheLastCall() {
        var sut = shell()
        let box = mailbox([file("old.txt", modified: 0), file("fresh.txt", modified: 10_000)],
                          lastVisit: t(5_000))
        let text = sut.handle(line: "FN", mailbox: box, now: t(20_000)).lines
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("fresh.txt"))
        XCTAssertFalse(text.contains("old.txt"))
    }

    func testNothingNewSaysWhenTheyLastCalled() {
        var sut = shell()
        let box = mailbox([file("old.txt", modified: 0)], lastVisit: t(5_000))
        let line = sut.handle(line: "FN", mailbox: box, now: t(9_000)).lines[0]
        XCTAssertTrue(line.contains("Nothing new"), line)
        XCTAssertTrue(line.contains("11/14"), line)
    }

    func testFirstCallHasNoSinceToOffer() {
        var sut = shell()
        let box = mailbox([file("a.txt")], lastVisit: nil)
        XCTAssertTrue(sut.handle(line: "FN", mailbox: box, now: t(0))
            .lines[0].contains("first call"))
    }

    // MARK: - One command for both kinds of file

    /// Text goes out as text: no protocol to negotiate, nothing the caller
    /// needs to have, and fewer bytes than any framing would cost. The caller
    /// never has to know which of the two they wanted.
    func testDownloadingTextSendsItAsText() {
        var sut = shell()
        let box = mailbox([file("net.txt", bytes: 512)])
        let out = sut.handle(line: "D net.txt", mailbox: box, now: t(0))
        XCTAssertEqual(out.effects, [.viewFile(file("net.txt", bytes: 512))])
        XCTAssertTrue(out.lines[0].contains("is text"), out.lines[0])
    }

    func testDownloadingABinaryRunsATransfer() {
        var sut = shell()
        let box = mailbox([file("map.png", bytes: 512)])
        XCTAssertEqual(sut.handle(line: "D map.png", mailbox: box, now: t(0)).effects,
                       [.sendFile(file("map.png", bytes: 512))])
    }

    /// Past the inline limit even text is worth framing, so it takes the
    /// transfer path — and the long-transfer confirmation with it.
    func testVeryLargeTextFallsBackToATransfer() {
        var sut = shell()
        let box = mailbox([file("huge.txt", bytes: 400_000)])
        let first = sut.handle(line: "D huge.txt", mailbox: box, now: t(0))
        XCTAssertTrue(first.effects.isEmpty)
        XCTAssertTrue(first.lines[0].contains("1h14m"), first.lines[0])

        XCTAssertEqual(sut.handle(line: "D huge.txt", mailbox: box, now: t(10)).effects,
                       [.sendFile(file("huge.txt", bytes: 400_000))])
    }

    // MARK: - Downloading

    func testShortDownloadStartsImmediately() {
        var sut = shell()
        let box = mailbox([file("small.bin", bytes: 2_048)])
        let out = sut.handle(line: "D small.bin", mailbox: box, now: t(0))
        XCTAssertEqual(out.effects, [.sendFile(file("small.bin", bytes: 2_048))])
    }

    /// A long transfer holds the channel against everyone else on it. Asking
    /// once costs a line; finding out forty minutes in costs the frequency.
    func testLongDownloadAsksFirst() {
        var sut = shell()
        let box = mailbox([file("big.bin", bytes: 146_432)])

        let first = sut.handle(line: "D big.bin", mailbox: box, now: t(0))
        XCTAssertTrue(first.effects.isEmpty, "must not start without confirmation")
        XCTAssertTrue(first.lines[0].contains("28m"), first.lines[0])
        XCTAssertTrue(first.lines[1].contains("again"), first.lines[1])

        let second = sut.handle(line: "D big.bin", mailbox: box, now: t(10))
        XCTAssertEqual(second.effects, [.sendFile(file("big.bin", bytes: 146_432))])
    }

    /// Confirming one file must not confirm a different one.
    func testConfirmationIsPerFile() {
        var sut = shell()
        let box = mailbox([file("big.bin", bytes: 146_432),
                           file("other.bin", bytes: 146_432)])
        _ = sut.handle(line: "D big.bin", mailbox: box, now: t(0))
        let out = sut.handle(line: "D other.bin", mailbox: box, now: t(10))
        XCTAssertTrue(out.effects.isEmpty, "a different file needs its own confirmation")
    }

    func testUnknownFilePointsAtTheListing() {
        var sut = shell()
        let box = mailbox([file("a.txt")])
        let out = sut.handle(line: "D nope.txt", mailbox: box, now: t(0))
        XCTAssertTrue(out.effects.isEmpty)
        XCTAssertTrue(out.lines[0].contains("W lists"), out.lines[0])
    }

    func testAmbiguousNameNamesTheAreas() {
        var sut = shell()
        let box = mailbox([file("readme.txt", area: "OPS"),
                           file("readme.txt", area: "FORMS")])
        let out = sut.handle(line: "D readme.txt", mailbox: box, now: t(0))
        XCTAssertTrue(out.effects.isEmpty)
        XCTAssertTrue(out.lines[0].contains("FORMS"), out.lines[0])
        XCTAssertTrue(out.lines[0].contains("OPS"), out.lines[0])
    }

    /// The shell has no filesystem access at all, and resolution is a lookup
    /// rather than a path join — so this is a name that matches nothing.
    func testTraversalAttemptDownloadsNothing() {
        var sut = shell()
        let box = mailbox([file("a.txt")])
        for attempt in ["D ../../etc/passwd", "D /etc/passwd", "D OPS/../../../etc/passwd"] {
            let out = sut.handle(line: attempt, mailbox: box, now: t(0))
            XCTAssertTrue(out.effects.isEmpty, "\(attempt) produced an effect")
        }
    }

    func testUsageForBareCommands() {
        var sut = shell()
        XCTAssertEqual(sut.handle(line: "D", mailbox: .init(), now: t(0)).lines,
                       ["Usage: D <name>"])
    }

    // MARK: - Conventions

    /// `V` is version and `W` is the file directory on every FBB-derived
    /// mailbox. A caller who has used packet before should not have to learn
    /// this one, so the letters match and the mnemonic spellings are aliases.
    func testCommandLettersFollowFBB() {
        var sut = shell()
        XCTAssertEqual(sut.handle(line: "V", mailbox: .init(), now: t(0)).lines,
                       [BBSShell.version])
        XCTAssertEqual(sut.handle(line: "VER", mailbox: .init(), now: t(0)).lines,
                       [BBSShell.version])

        let box = mailbox([file("a.txt", area: "OPS")])
        let byW = sut.handle(line: "W", mailbox: box, now: t(0)).lines
        let byF = sut.handle(line: "F", mailbox: box, now: t(0)).lines
        XCTAssertEqual(byW, byF, "F must stay an alias for W")
        XCTAssertTrue(byW.contains { $0.contains("OPS") })
    }

    func testNewFilesAnswersToBothSpellings() {
        var sut = shell()
        let box = mailbox([file("a.txt", modified: 10_000)], lastVisit: t(5_000))
        XCTAssertEqual(sut.handle(line: "WN", mailbox: box, now: t(20_000)).lines,
                       sut.handle(line: "FN", mailbox: box, now: t(20_000)).lines)
    }

    // MARK: - Uploads

    func testUploadArmsTheReceiver() {
        var sut = shell()
        let out = sut.handle(line: "U", mailbox: .init(), now: t(0))
        XCTAssertEqual(out.effects, [.beginUpload])
    }

    /// `A` is FBB's abort, and a caller who has started something they did not
    /// mean to needs one command that works from anywhere.
    func testAbortStopsWhateverIsRunning() {
        var sut = shell()
        let box = mailbox([file("big.bin", bytes: 146_432)])
        _ = sut.handle(line: "D big.bin", mailbox: box, now: t(0))

        let out = sut.handle(line: "A", mailbox: box, now: t(10))
        XCTAssertEqual(out.effects, [.abortTransfer])

        // And it clears the pending confirmation, so the next D asks again
        // rather than starting something the caller just stopped.
        XCTAssertTrue(sut.handle(line: "D big.bin", mailbox: box, now: t(20)).effects.isEmpty)
    }
}
