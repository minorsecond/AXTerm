//
//  XIDAXTermMarkerTests.swift
//  AXTermTests
//
//  An AXTerm marker in the XID AXTerm already sends at link setup
//  (operator, 2026-10-11; `Docs/XIDCapabilityMarkerResearch.md`). The
//  command carries the question; another AXTerm answers it in its XID
//  response with a different role byte, and nothing else ever does. BPQ
//  builds its XID response by editing the command it received, so an
//  echoed question proves nothing. Off until the loopback tests against
//  Dire Wolf and other stacks have passed.
//

import XCTest
@testable import AXTerm

final class XIDAXTermMarkerEncodingTests: XCTestCase {

    private func body(of info: Data) -> [UInt8] { Array(info.dropFirst(4)) }

    /// Last in group 0x80, PL exactly 4 (Dire Wolf stops parsing on PL 0
    /// or above 4), and the group length counts it.
    func testTheQuestionGoesLastWithFourBytes() {
        var params = AX25XIDParameters()
        params.supportsSREJ = true
        params.iFieldLengthRx = 256
        params.windowSizeRx = 4
        params.axtermMarker = .question
        let info = params.encoded(isCommand: true)
        let bytes = [UInt8](info)
        XCTAssertEqual(Int(bytes[2]) << 8 | Int(bytes[3]), bytes.count - 4, "GL counts every byte")
        let tail = Array(bytes.suffix(6))
        XCTAssertEqual(tail[0], AX25XIDParameters.axtermMarkerPI)
        XCTAssertEqual(tail[1], 4)
        XCTAssertEqual(Array(tail[2...]), AX25XIDParameters.AXTermMarker.question.value)
    }

    /// Not a PI BPQ uses for its own compression (16, 17) or one named in
    /// Dire Wolf (65 to 67), and above the spec's 2 to 10 so the order
    /// stays ascending.
    func testThePIStaysClearOfOthers() {
        let pi = Int(AX25XIDParameters.axtermMarkerPI)
        XCTAssertGreaterThan(pi, 10)
        XCTAssertFalse([16, 17, 65, 66, 67].contains(pi))
    }

    func testTheQuestionAndTheAnswerDiffer() {
        XCTAssertNotEqual(AX25XIDParameters.AXTermMarker.question.value,
                          AX25XIDParameters.AXTermMarker.answer.value)
    }

    func testTheKnownParametersReadTheSameWithTheMarker() throws {
        var plain = AX25XIDParameters()
        plain.supportsSREJ = true
        plain.iFieldLengthRx = 256
        plain.windowSizeRx = 4
        var marked = plain
        marked.axtermMarker = .answer
        let a = try XCTUnwrap(AX25XIDParameters.parse(plain.encoded(isCommand: false)))
        let b = try XCTUnwrap(AX25XIDParameters.parse(marked.encoded(isCommand: false)))
        XCTAssertNil(a.axtermMarker)
        XCTAssertEqual(b.axtermMarker, .answer)
        var stripped = b
        stripped.axtermMarker = nil
        XCTAssertEqual(stripped, a)
    }

    func testNoMarkerUnlessAsked() {
        let info = AX25XIDParameters().encoded(isCommand: true)
        XCTAssertNil(AX25XIDParameters.parse(info)?.axtermMarker)
        XCTAssertFalse(body(of: info).contains(AX25XIDParameters.axtermMarkerPI))
    }
}

@MainActor
final class XIDAXTermMarkerNegotiationTests: XCTestCase {

    private var manager: AX25SessionManager!
    private var clock: AX25VirtualClock!
    private var sent: [OutboundFrame] = []
    private var verdicts: [(peer: String, isAXTerm: Bool)] = []
    private let peer = AX25Address(call: "K0EPI", ssid: 3)

    override func setUp() {
        super.setUp()
        clock = AX25VirtualClock()
        manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 2), clock: clock)
        manager.xidMemory = XIDAnswerMemory(defaults: TestDefaults.make("XIDAXTermMarkerTests"))
        manager.defaultConfig = AX25SessionConfig(windowSize: 4, paclen: 128, rtoMin: 2.0, rtoMax: 8.0,
                                                  initialRto: 2.0)
        manager.negotiateV22 = true
        manager.sendsAXTermXIDMarker = true
        sent = []
        verdicts = []
        manager.onSendFrame = { [weak self] in self?.sent.append($0) }
        manager.onXIDShowedAXTerm = { [weak self] peer, isAXTerm in self?.verdicts.append((peer, isAXTerm)) }
    }

    override func tearDown() {
        manager = nil
        clock = nil
        super.tearDown()
    }

    private func info(_ marker: AX25XIDParameters.AXTermMarker?, isCommand: Bool) -> Data {
        var params = AX25XIDParameters()
        params.supportsSREJ = true
        params.axtermMarker = marker
        return params.encoded(isCommand: isCommand)
    }

    func testOurCommandAsks() throws {
        let frame = try XCTUnwrap(manager.connect(to: peer, path: DigiPath(), radio: .primary))
        XCTAssertEqual(frame.displayInfo, "XID")
        XCTAssertEqual(AX25XIDParameters.parse(frame.payload)?.axtermMarker, .question)
    }

    func testAnAnswerMarksThePeerAXTerm() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundXID(from: peer, path: DigiPath(), radio: .primary,
                                     info: info(.answer, isCommand: false), isCommand: false, pf: true)
        XCTAssertEqual(verdicts.map(\.isAXTerm), [true])
        XCTAssertEqual(verdicts.first?.peer, peer.display)
    }

    /// BPQ edits the received command into its response, so the question
    /// comes back unchanged: that is not another AXTerm.
    func testAnEchoedQuestionIsNotAXTerm() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundXID(from: peer, path: DigiPath(), radio: .primary,
                                     info: info(.question, isCommand: false), isCommand: false, pf: true)
        XCTAssertEqual(verdicts.map(\.isAXTerm), [false])
    }

    func testAResponseWithoutTheMarkerIsNotAXTerm() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundXID(from: peer, path: DigiPath(), radio: .primary,
                                     info: info(nil, isCommand: false), isCommand: false, pf: true)
        XCTAssertEqual(verdicts.map(\.isAXTerm), [false])
    }

    func testFRMRAndDMAreNotAXTerm() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        manager.handleInboundFRMRDuringNegotiation(from: peer, radio: .primary)
        let other = AX25Address(call: "N0NODE", ssid: 7)
        _ = manager.connect(to: other, path: DigiPath(), radio: .primary)
        manager.handleInboundDMDuringNegotiation(from: other, radio: .primary)
        XCTAssertEqual(verdicts.map(\.isAXTerm), [false, false])
    }

    /// Silence is no answer at all: the reply may simply have been lost.
    func testSilenceIsNoVerdict() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        clock.advance(by: 10)
        XCTAssertTrue(verdicts.isEmpty)
    }

    /// A caller's question is answered, and the caller is AXTerm.
    func testAQuestionIsAnsweredAndTheCallerIsAXTerm() throws {
        let replies = manager.handleInboundXID(from: peer, path: DigiPath(), radio: .primary,
                                               info: info(.question, isCommand: true), isCommand: true, pf: true)
        let reply = try XCTUnwrap(replies.first)
        XCTAssertEqual(AX25XIDParameters.parse(reply.payload)?.axtermMarker, .answer)
        XCTAssertEqual(verdicts.map(\.isAXTerm), [true])
    }

    /// Everyone else's XID is answered byte for byte as before.
    func testACommandWithoutTheQuestionGetsNoAnswerForm() throws {
        let replies = manager.handleInboundXID(from: peer, path: DigiPath(), radio: .primary,
                                               info: info(nil, isCommand: true), isCommand: true, pf: true)
        XCTAssertNil(AX25XIDParameters.parse(try XCTUnwrap(replies.first).payload)?.axtermMarker)
        XCTAssertTrue(verdicts.isEmpty)
    }

    /// Off (the default until the loopback tests pass): no question, no
    /// answer, no verdicts.
    func testOffSendsNothingNew() throws {
        manager.sendsAXTermXIDMarker = false
        let frame = try XCTUnwrap(manager.connect(to: peer, path: DigiPath(), radio: .primary))
        XCTAssertNil(AX25XIDParameters.parse(frame.payload)?.axtermMarker)
        let replies = manager.handleInboundXID(from: AX25Address(call: "N0ABC", ssid: 1), path: DigiPath(),
                                               radio: .primary, info: info(.question, isCommand: true),
                                               isCommand: true, pf: true)
        XCTAssertNil(AX25XIDParameters.parse(try XCTUnwrap(replies.first).payload)?.axtermMarker)
        XCTAssertTrue(verdicts.isEmpty)
        XCTAssertFalse(AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 2)).sendsAXTermXIDMarker)
    }
}
