import XCTest
@testable import AXTerm

/// The marker lines a mailbox puts around a typed-out text file, the byte
/// count they carry, and the receiver that turns the lines back into the
/// file. Pure: no session, no files.
final class TextDownloadMarkersTests: XCTestCase {

    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func line(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Marker lines

    func testMarkerLinesCarryTheNameAndTheCount() {
        XCTAssertEqual(TextDownloadMarkers.beginLine(name: "t3k_text.txt", byteCount: 3010),
                       "--- BEGIN t3k_text.txt (3010 bytes) ---")
        XCTAssertEqual(TextDownloadMarkers.beginLine(name: "a.txt", byteCount: 1),
                       "--- BEGIN a.txt (1 byte) ---")
        XCTAssertEqual(TextDownloadMarkers.endLine(name: "t3k_text.txt"),
                       "--- END t3k_text.txt ---")
    }

    func testABeginLineParsesBackToItsNameAndCount() {
        let begin = TextDownloadMarkers.parseBegin("--- BEGIN t3k_text.txt (3010 bytes) ---")
        XCTAssertEqual(begin, TextDownloadMarkers.Begin(name: "t3k_text.txt", byteCount: 3010))
        XCTAssertEqual(TextDownloadMarkers.parseBegin("--- BEGIN a.txt (1 byte) ---"),
                       TextDownloadMarkers.Begin(name: "a.txt", byteCount: 1))
        // A name with spaces and parentheses of its own still parses, because
        // the count is read from the end of the line.
        XCTAssertEqual(TextDownloadMarkers.parseBegin("--- BEGIN net (draft) v2.txt (12 bytes) ---"),
                       TextDownloadMarkers.Begin(name: "net (draft) v2.txt", byteCount: 12))
    }

    func testLinesThatOnlyLookLikeABeginAreNotOne() {
        for text in [
            "--- notes.txt ---",
            "--- BEGIN notes.txt ---",
            "--- BEGIN notes.txt (12 bytes)",
            "--- BEGIN notes.txt (twelve bytes) ---",
            "--- BEGIN notes.txt (+12 bytes) ---",
            "--- BEGIN notes.txt (-12 bytes) ---",
            "--- BEGIN notes.txt (12 octets) ---",
            "--- BEGIN  (12 bytes) ---",
            " --- BEGIN notes.txt (12 bytes) ---",
            "--- BEGIN notes.txt (99999999999 bytes) ---",
        ] {
            XCTAssertNil(TextDownloadMarkers.parseBegin(text), text)
        }
    }

    // MARK: - What the mailbox sends

    func testTheCountIsTheFileWithLFLineEndings() {
        let body = TextDownloadMarkers.body(of: data("Net at 1900\nCheck in by suffix\n"))
        XCTAssertEqual(body.lines, ["Net at 1900", "Check in by suffix"],
                       "the final newline ends the last line; it does not start an empty one")
        XCTAssertEqual(body.byteCount, 31)
    }

    func testCRLFAndBareCRCountAsOneLineEnding() {
        let body = TextDownloadMarkers.body(of: data("one\r\ntwo\rthree\n"))
        XCTAssertEqual(body.lines, ["one", "two", "three"])
        XCTAssertEqual(body.byteCount, "one\ntwo\nthree\n".utf8.count)
    }

    func testBlankLinesAndOtherControlCharactersAreKept() {
        let body = TextDownloadMarkers.body(of: data("a\n\n\u{0C}page two\n\n"))
        XCTAssertEqual(body.lines, ["a", "", "\u{0C}page two", ""],
                       "a form feed is not a line ending; blank lines are lines")
        XCTAssertEqual(body.byteCount, 14)
    }

    func testAFileWithoutAFinalNewlineCountsWithoutOne() {
        let body = TextDownloadMarkers.body(of: data("last line"))
        XCTAssertEqual(body.lines, ["last line"])
        XCTAssertEqual(body.byteCount, 9)
    }

    func testMarkedLinesWrapTheBody() {
        XCTAssertEqual(TextDownloadMarkers.markedLines(name: "n.txt", data: data("x\ny\n")),
                       ["--- BEGIN n.txt (4 bytes) ---", "x", "y", "--- END n.txt ---"])
    }

    // MARK: - Splitting received bytes into lines

    func testTheSplitterKeepsBlankLinesAndTreatsCRLFAsOneEnding() {
        var splitter = ReceivedLineSplitter()
        var lines = splitter.push(data("a\r\rb\r"))
        lines += splitter.push(data("\nc\r"))   // CRLF split across two frames
        lines += splitter.push(data("d\ne"))
        XCTAssertEqual(lines, [line("a"), line(""), line("b"), line("c"), line("d")])
        XCTAssertEqual(splitter.flush(), line("e"))
        XCTAssertNil(splitter.flush())
    }

    // MARK: - The receiver

    private func feed(_ receiver: inout TextDownloadReceiver, _ lines: [String]) -> [TextDownloadReceiver.Result] {
        lines.compactMap { receiver.receive(line: Data($0.utf8)) }
    }

    private func roundTrip(_ source: String, name: String = "f.txt") -> [TextDownloadReceiver.Result] {
        var receiver = TextDownloadReceiver()
        let marked = TextDownloadMarkers.markedLines(name: name, data: data(source))
        return feed(&receiver, ["chatter before"] + marked + [">"])
    }

    func testAMarkedFileComesBackByteIdentical() {
        for source in ["Net at 1900\nCheck in by suffix\n",
                       "no final newline",
                       "blank\n\nlines\n\n",
                       "\n",
                       "tabs\tand \u{0C} feeds\n",
                       "unicode: 73 de K0EPI \u{1F4FB}\n"] {
            let results = roundTrip(source)
            XCTAssertEqual(results.count, 1, source)
            XCTAssertEqual(results.first?.data, data(source), source)
            XCTAssertNil(results.first?.problem, source)
            XCTAssertEqual(results.first?.name, "f.txt")
        }
    }

    func testCRLFSourceComesBackWithLFEndingsAndTheCountStillMatches() {
        let results = roundTrip("one\r\ntwo\r\n")
        XCTAssertEqual(results.first?.data, data("one\ntwo\n"))
        XCTAssertNil(results.first?.problem)
    }

    func testAnEndLineInsideTheFileDoesNotEndItEarly() {
        let source = "before\n--- END f.txt ---\nafter\n--- BEGIN f.txt (3 bytes) ---\n"
        let results = roundTrip(source)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.data, data(source),
                       "the count decides where the file ends, so marker-like lines are just text")
        XCTAssertNil(results.first?.problem)
    }

    func testAFileWhoseLastLineIsAnEndLineStillEndsInTheRightPlace() {
        let source = "x\n--- END f.txt ---"
        let results = roundTrip(source)
        XCTAssertEqual(results.first?.data, data(source))
        XCTAssertNil(results.first?.problem)
    }

    func testMissingLinesAreReportedAndWhatArrivedIsKept() {
        var receiver = TextDownloadReceiver()
        let results = feed(&receiver, ["--- BEGIN f.txt (30 bytes) ---", "only ten b", "--- END f.txt ---",
                                       ">", "next command output", "more output that runs past the count"])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.data, data("only ten b\n"),
                       "the end line that came early marks where the file stopped")
        XCTAssertNotNil(results.first?.problem)
        XCTAssertTrue(results.first?.problem?.contains("11 of 30 bytes") ?? false,
                      results.first?.problem ?? "")
        XCTAssertFalse(receiver.isReceiving)
    }

    func testMoreThanTheCountWithNoEndLineIsReported() {
        var receiver = TextDownloadReceiver()
        let results = feed(&receiver, ["--- BEGIN f.txt (4 bytes) ---", "abc", "def", "ghi"])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.data, data("abc\n"))
        XCTAssertNotNil(results.first?.problem)
        XCTAssertFalse(receiver.isReceiving)
    }

    func testAnEndLineForAnotherFileIsJustText() {
        var receiver = TextDownloadReceiver()
        let results = feed(&receiver, ["--- BEGIN f.txt (18 bytes) ---", "--- END g.txt ---", "--- END f.txt ---"])
        XCTAssertEqual(results.first?.data, data("--- END g.txt ---\n"))
        XCTAssertNil(results.first?.problem)
    }

    func testTheLinkClosingMidFileReportsWhatArrived() {
        var receiver = TextDownloadReceiver()
        XCTAssertTrue(feed(&receiver, ["--- BEGIN f.txt (100 bytes) ---", "first", "second"]).isEmpty)
        XCTAssertTrue(receiver.isReceiving)
        let result = receiver.linkClosed()
        XCTAssertEqual(result?.data, data("first\nsecond\n"))
        XCTAssertTrue(result?.problem?.contains("13 of 100 bytes") ?? false, result?.problem ?? "")
        XCTAssertFalse(receiver.isReceiving)
        XCTAssertNil(receiver.linkClosed(), "nothing to report twice")
    }

    func testNothingIsReportedWithoutABegin() {
        var receiver = TextDownloadReceiver()
        XCTAssertTrue(feed(&receiver, ["hello", "--- END f.txt ---", "--- f.txt ---"]).isEmpty)
        XCTAssertNil(receiver.linkClosed())
    }

    func testTwoDownloadsInARow() {
        var receiver = TextDownloadReceiver()
        let lines = TextDownloadMarkers.markedLines(name: "a.txt", data: data("A\n"))
            + [">"]
            + TextDownloadMarkers.markedLines(name: "b.txt", data: data("B\n"))
        let results = feed(&receiver, lines)
        XCTAssertEqual(results.map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(results.map(\.data), [data("A\n"), data("B\n")])
    }

    // MARK: - Capture

    func testCaptureNamesTheFileFromTheStationAndTheTime() {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 1
        components.hour = 6; components.minute = 3
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "America/Denver")!
        calendar.timeZone = zone
        let date = calendar.date(from: components)!
        XCTAssertEqual(SessionCapture.fileName(peer: "K0EPI-8", startedAt: date, timeZone: zone),
                       "K0EPI-8 2026-10-01 0603.txt")
    }

    func testCaptureKeepsLinesWithLFEndings() {
        var capture = SessionCapture(peer: "K0EPI-8", startedAt: Date())
        capture.append(line: line("one"))
        capture.append(line: line(""))
        capture.append(line: line("three"))
        XCTAssertEqual(capture.data, data("one\n\nthree\n"))
        XCTAssertEqual(capture.lineCount, 3)
    }

    func testIncompleteNamesSaySo() {
        XCTAssertEqual(ReceivedText.incompleteName(for: "t3k_text.txt"), "t3k_text (incomplete).txt")
        XCTAssertEqual(ReceivedText.incompleteName(for: "README"), "README (incomplete)")
    }

    // MARK: - Saying where it went

    func testTheNoticeNamesTheFolderInEachPlatformsWords() {
        let text = ReceivedText(source: .download(announcedBytes: 12), peer: "K0EPI-2",
                                name: "n.txt", data: data("Net at 1900\n"), problem: nil)
        let mac = SessionCoordinator.receivedTextNotice(text, savedName: "n.txt", platform: .macOS)
        XCTAssertEqual(mac, "Saved n.txt from K0EPI-2 (12 bytes) as \"n.txt\" in Downloads \u{203A} AXTerm Transfers.")
        let iOS = SessionCoordinator.receivedTextNotice(text, savedName: "n 2.txt", platform: .iOS)
        XCTAssertEqual(iOS, "Saved n.txt from K0EPI-2 (12 bytes) as \"n 2.txt\" in the Files app, "
                       + "in AXTerm \u{203A} AXTerm Transfers.")
    }

    func testAnIncompleteNoticeSaysWhatIsMissing() {
        let text = ReceivedText(source: .download(announcedBytes: 40), peer: "K0EPI-2", name: "s.txt",
                                data: data("abc\n"), problem: "The link closed after 4 of 40 bytes.")
        let notice = SessionCoordinator.receivedTextNotice(text, savedName: "s (incomplete).txt", platform: .macOS)
        XCTAssertTrue(notice.contains("did not arrive complete"), notice)
        XCTAssertTrue(notice.contains("4 of 40 bytes"), notice)
        XCTAssertTrue(notice.contains("\"s (incomplete).txt\""), notice)
    }

    func testTextIsNeverOfferedAsAWayToSend() {
        guard case .unavailable = TransferSendRoute.route(for: .text) else {
            return XCTFail("nothing sends Text; it is only received")
        }
        XCTAssertFalse(TransferProtocolRegistry.shared
            .availableProtocols(for: "K0EPI-2", hasAXDP: true, isConnected: true).contains(.text))
    }
}
