import XCTest
@testable import AXTerm

final class B2FProposalTests: XCTestCase {

    // MARK: - FC line rendering and parsing

    func testProposalRendering() {
        let proposal = B2FProposal.Proposal(
            kind: .encapsulatedMessage, mid: "ABC123XYZ456", uncompressedSize: 1234, compressedSize: 987)
        XCTAssertEqual(proposal.rendered, "FC EM ABC123XYZ456 1234 987 0\r")
    }

    func testProposalParsing() {
        let parsed = B2FProposal.Proposal.parse("FC EM ABC123XYZ456 1234 987 0")
        XCTAssertEqual(parsed, B2FProposal.Proposal(
            kind: .encapsulatedMessage, mid: "ABC123XYZ456", uncompressedSize: 1234, compressedSize: 987))
    }

    func testProposalParsingRejectsMalformed() {
        XCTAssertNil(B2FProposal.Proposal.parse("FC EM ONLYTHREE 12"))
        XCTAssertNil(B2FProposal.Proposal.parse("FB EM X 1 1 0"))
        XCTAssertNil(B2FProposal.Proposal.parse("FC ZZ X 1 1 0"))
        XCTAssertNil(B2FProposal.Proposal.parse("FC EM X abc 1 0"))
    }

    // MARK: - Proposal block checksum

    func testRenderBlockChecksumValidatesRoundTrip() {
        let proposals = [
            B2FProposal.Proposal(kind: .encapsulatedMessage, mid: "MID000000001", uncompressedSize: 100, compressedSize: 80),
            B2FProposal.Proposal(kind: .encapsulatedMessage, mid: "MID000000002", uncompressedSize: 5000, compressedSize: 2100),
        ]
        let block = B2FProposal.renderBlock(proposals)

        XCTAssertTrue(block.hasSuffix("\r"))
        let lines = block.split(separator: "\r").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[2].hasPrefix("F> "))

        let checksumHex = String(lines[2].dropFirst(3))
        XCTAssertEqual(checksumHex.count, 2)
        XCTAssertTrue(B2FProposal.validateBlockChecksum(
            fcLines: [lines[0], lines[1]], checksumHex: checksumHex))
        XCTAssertFalse(B2FProposal.validateBlockChecksum(
            fcLines: [lines[0]], checksumHex: checksumHex))
    }

    /// The checksum must include each FC line's trailing CR — a subtle
    /// spec detail that breaks interop when missed.
    func testBlockChecksumIncludesCR() {
        let proposal = B2FProposal.Proposal(
            kind: .encapsulatedMessage, mid: "M", uncompressedSize: 1, compressedSize: 1)
        let block = B2FProposal.renderBlock([proposal])
        let checksumHex = String(block.split(separator: "\r").last!.dropFirst(3))

        let withCR = B2FChecksum.negatedByteSum(of: Array("FC EM M 1 1 0\r".utf8))
        let withoutCR = B2FChecksum.negatedByteSum(of: Array("FC EM M 1 1 0".utf8))
        XCTAssertEqual(checksumHex, String(format: "%02X", withCR))
        XCTAssertNotEqual(withCR, withoutCR)
    }

    // MARK: - FS answer parsing

    func testParseSimpleAnswers() {
        XCTAssertEqual(B2FProposal.parseAnswers("FS YNY"), [.accept, .reject, .accept])
        XCTAssertEqual(B2FProposal.parseAnswers("FS +-="), [.accept, .reject, .defer_])
        XCTAssertEqual(B2FProposal.parseAnswers("FS LRHE"), [.defer_, .reject, .defer_, .reject])
    }

    func testParseOffsetAnswers() {
        XCTAssertEqual(B2FProposal.parseAnswers("FS !247"), [.acceptFromOffset(247)])
        XCTAssertEqual(B2FProposal.parseAnswers("FS A1024Y"), [.acceptFromOffset(1024), .accept])
        XCTAssertEqual(B2FProposal.parseAnswers("FS +100N"), [.acceptFromOffset(100), .reject])
        XCTAssertEqual(B2FProposal.parseAnswers("FS !0"), [.accept], "offset zero is a plain accept")
    }

    func testParseAnswersCapsOffset() {
        XCTAssertEqual(B2FProposal.parseAnswers("FS !99999999"), [.acceptFromOffset(999_999)])
    }

    func testParseAnswersRejectsGarbage() {
        XCTAssertNil(B2FProposal.parseAnswers("FF"))
        XCTAssertNil(B2FProposal.parseAnswers("FS YXZ"))
    }

    func testAnswerRendering() {
        XCTAssertEqual(B2FProposal.Answer.accept.rendered, "Y")
        XCTAssertEqual(B2FProposal.Answer.reject.rendered, "N")
        XCTAssertEqual(B2FProposal.Answer.defer_.rendered, "=")
        XCTAssertEqual(B2FProposal.Answer.acceptFromOffset(512).rendered, "!512")
    }
}
