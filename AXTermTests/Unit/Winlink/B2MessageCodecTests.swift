import XCTest
@testable import AXTerm

final class B2MessageCodecTests: XCTestCase {

    // MARK: - Parsing the real captured message (wl2k-go fixture)

    func testParseRealCapturedMessage() throws {
        let message = try WinlinkB2Message.parse(LZHUFFixtures.b2fMessage)

        XCTAssertEqual(message.mid, "LPE5NXDVLVSQ")
        XCTAssertEqual(message.type, .privateMessage)
        XCTAssertEqual(message.from, "LA5NTA")
        XCTAssertEqual(message.to, ["LA4TTA"])
        XCTAssertEqual(message.cc, [])
        XCTAssertEqual(message.subject, "73 fra Brekke")
        XCTAssertEqual(message.mbo, "LA5NTA")
        XCTAssertEqual(message.body.count, 104)
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(message.attachments[0].name, "1469042410710.jpg")
        XCTAssertEqual(message.attachments[0].data.count, 31028)
        // JPEG magic at the start of the attachment proves offsets are right.
        XCTAssertEqual(Array(message.attachments[0].data.prefix(2)), [0xff, 0xd8])

        let expectedDate = WinlinkB2Message.dateFormatter.date(from: "2016/07/20 19:21")
        XCTAssertEqual(message.date, expectedDate)

        // Body is ISO-8859-1 Norwegian text.
        let bodyText = String(data: message.body, encoding: .isoLatin1)
        XCTAssertTrue(bodyText?.contains("Hei!") == true)
        XCTAssertTrue(bodyText?.contains("prøver") == true)
    }

    func testSemanticRoundTripOfRealMessage() throws {
        let original = try WinlinkB2Message.parse(LZHUFFixtures.b2fMessage)
        let reencoded = try original.encode()
        let reparsed = try WinlinkB2Message.parse(reencoded)
        XCTAssertEqual(reparsed, original)
    }

    // MARK: - Encoding

    func testEncodeProducesExpectedLayout() throws {
        let message = WinlinkB2Message(
            mid: "ABC123XYZ456",
            date: WinlinkB2Message.dateFormatter.date(from: "2026/08/23 12:00")!,
            type: .privateMessage,
            from: "K0EPI",
            to: ["N0CALL", "SMTP:someone@example.com"],
            cc: ["W1AW"],
            subject: "Test message",
            mbo: "K0EPI",
            body: Data("Hello\r\nWorld\r\n".utf8),
            attachments: [.init(name: "a.bin", data: Data([0x00, 0x01, 0xff]))]
        )

        let encoded = try message.encode()
        let text = String(data: encoded, encoding: .isoLatin1)!

        XCTAssertTrue(text.hasPrefix("Mid: ABC123XYZ456\r\n"))
        XCTAssertTrue(text.contains("Date: 2026/08/23 12:00\r\n"))
        XCTAssertTrue(text.contains("Type: Private\r\n"))
        XCTAssertTrue(text.contains("To: N0CALL\r\nTo: SMTP:someone@example.com\r\n"))
        XCTAssertTrue(text.contains("Cc: W1AW\r\n"))
        XCTAssertTrue(text.contains("Body: 14\r\n"))
        XCTAssertTrue(text.contains("File: 3 a.bin\r\n"))

        let reparsed = try WinlinkB2Message.parse(encoded)
        XCTAssertEqual(reparsed, message)
    }

    func testEncodeRejectsOverlongSubjectAndMID() {
        var message = makeMinimalMessage()
        message.subject = String(repeating: "x", count: 129)
        XCTAssertThrowsError(try message.encode()) {
            XCTAssertEqual($0 as? WinlinkB2Message.CodecError, .subjectTooLong)
        }

        message = makeMinimalMessage()
        message.mid = "TOOLONGMID1234"
        XCTAssertThrowsError(try message.encode()) {
            XCTAssertEqual($0 as? WinlinkB2Message.CodecError, .midTooLong)
        }
    }

    func testRoundTripEmptyBodyNoAttachments() throws {
        let message = makeMinimalMessage()
        let reparsed = try WinlinkB2Message.parse(try message.encode())
        XCTAssertEqual(reparsed, message)
    }

    func testRoundTripBinaryAttachmentWithCRLFBytes() throws {
        // Attachment containing CR/LF/NUL bytes must not confuse framing —
        // lengths, not separators, delimit the payloads.
        var message = makeMinimalMessage()
        message.attachments = [
            .init(name: "tricky.dat", data: Data([0x0d, 0x0a, 0x0d, 0x0a, 0x00, 0x01])),
            .init(name: "second.dat", data: Data(repeating: 0x0d, count: 100)),
        ]
        let reparsed = try WinlinkB2Message.parse(try message.encode())
        XCTAssertEqual(reparsed, message)
    }

    // MARK: - Malformed input

    func testParseRejectsMissingHeaderTerminator() {
        XCTAssertThrowsError(try WinlinkB2Message.parse(Data("Mid: X\r\nBody: 0\r\n".utf8)))
    }

    func testParseRejectsTruncatedBody() {
        let data = Data("Mid: X\r\nFrom: A\r\nBody: 50\r\n\r\nshort".utf8)
        XCTAssertThrowsError(try WinlinkB2Message.parse(data)) {
            guard case .truncatedBody = $0 as? WinlinkB2Message.CodecError else {
                return XCTFail("wrong error: \($0)")
            }
        }
    }

    func testParseRejectsTruncatedAttachment() {
        let data = Data("Mid: X\r\nFrom: A\r\nBody: 2\r\nFile: 99 f.bin\r\n\r\nhi\r\nx".utf8)
        XCTAssertThrowsError(try WinlinkB2Message.parse(data)) {
            guard case .truncatedAttachment = $0 as? WinlinkB2Message.CodecError else {
                return XCTFail("wrong error: \($0)")
            }
        }
    }

    func testParseToleratesUnknownHeaders() throws {
        let data = Data("Mid: X\r\nFrom: A\r\nContent-Type: text/plain\r\nX-Custom: hi\r\nBody: 2\r\n\r\nok\r\n".utf8)
        let message = try WinlinkB2Message.parse(data)
        XCTAssertEqual(message.body, Data("ok".utf8))
    }

    // MARK: - MID generation

    func testGeneratedMIDFormat() {
        let mid = WinlinkB2Message.generateMID(callsign: "K0EPI")
        XCTAssertEqual(mid.count, 12)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        XCTAssertTrue(mid.allSatisfy { allowed.contains($0) }, "unexpected chars in \(mid)")
    }

    func testGeneratedMIDsAreUnique() {
        let mids = Set((0..<100).map { _ in WinlinkB2Message.generateMID(callsign: "K0EPI") })
        XCTAssertEqual(mids.count, 100)
    }

    // MARK: - Helpers

    private func makeMinimalMessage() -> WinlinkB2Message {
        WinlinkB2Message(
            mid: "MINIMAL00001",
            date: WinlinkB2Message.dateFormatter.date(from: "2026/01/01 00:00")!,
            type: .privateMessage,
            from: "K0EPI",
            to: ["N0CALL"],
            cc: [],
            subject: "s",
            mbo: "K0EPI",
            body: Data(),
            attachments: []
        )
    }
}
