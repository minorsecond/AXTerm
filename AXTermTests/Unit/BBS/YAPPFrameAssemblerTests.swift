import XCTest
@testable import AXTerm

/// Separating a caller's YAPP replies from what they type during a mailbox
/// download.
///
/// The replies are YAPP's own two-byte and counted frames (the WA7MBL table);
/// anything else is the caller typing, which has to be heard so `A` stops
/// the transfer. These pin every reply kind, split at every byte, joined,
/// and mixed with text.
final class YAPPFrameAssemblerTests: XCTestCase {

    /// Everything a receiving caller can send back.
    private var everyReply: [Data] {
        [
            YAPPEncoder.receiveReady(),
            YAPPEncoder.receiveFile(),
            YAPPEncoder.receiveFileWithChecksum(),
            YAPPEncoder.ackEndFile(),
            YAPPEncoder.ackEndTransmission(),
            YAPPEncoder.ackCancel(),
            YAPPEncoder.notReady(reason: "Disk full"),
            YAPPEncoder.cancel(reason: "Stopped"),
            YAPPEncoder.notReady(reason: ""),
        ]
    }

    func testEachReplyArrivingWholeComesOutWhole() {
        for reply in everyReply {
            var assembler = YAPPFrameAssembler()
            XCTAssertEqual(assembler.push(reply), [.frame(reply)], "\(Array(reply))")
            XCTAssertTrue(assembler.isEmpty)
        }
    }

    func testEachReplySplitAtEveryByteComesOutOnceAndWhole() {
        for reply in everyReply where reply.count > 1 {
            for cut in 1..<reply.count {
                var assembler = YAPPFrameAssembler()
                XCTAssertEqual(assembler.push(reply.prefix(cut)), [],
                               "nothing until the frame is complete (cut \(cut))")
                XCTAssertEqual(assembler.push(reply.dropFirst(cut)), [.frame(reply)],
                               "cut at \(cut)")
            }
        }
    }

    func testRepliesJoinedInOneDeliveryComeOutSeparately() {
        var assembler = YAPPFrameAssembler()
        let joined = everyReply.reduce(Data(), +)
        XCTAssertEqual(assembler.push(joined), everyReply.map { .frame($0) })
    }

    func testByteAtATimeDeliveryStillAssemblesEverything() {
        var assembler = YAPPFrameAssembler()
        var pieces: [YAPPFrameAssembler.Piece] = []
        for byte in everyReply.reduce(Data(), +) {
            pieces += assembler.push(Data([byte]))
        }
        XCTAssertEqual(pieces, everyReply.map { .frame($0) })
    }

    func testTypedTextIsHandedBackAsText() {
        var assembler = YAPPFrameAssembler()
        let rr = YAPPEncoder.receiveReady()
        XCTAssertEqual(assembler.push(Data("A\r".utf8) + rr + Data("hi".utf8)),
                       [.text(Data("A\r".utf8)), .frame(rr), .text(Data("hi".utf8))],
                       "a caller whose software has no YAPP can still type A")
    }

    /// The frames the sending side itself produces are measured the same way,
    /// so a caller echoing them back is not misread as text.
    func testSenderFramesHaveTheirTableLengths() {
        let block = YAPPEncoder.data(Data((0..<200).map { UInt8($0) }), checksum: false)
        let full = YAPPEncoder.data(Data(repeating: 0x41, count: 256), checksum: false)
        for frame in [YAPPEncoder.sendInit(), YAPPEncoder.header(name: "ROSTER.BIN", size: 4096),
                      block, full, YAPPEncoder.endFile(), YAPPEncoder.endTransmission()] {
            var assembler = YAPPFrameAssembler()
            XCTAssertEqual(assembler.push(frame), [.frame(frame)], "\(Array(frame.prefix(3)))")
        }
    }

    func testResetDropsAPartialFrame() {
        var assembler = YAPPFrameAssembler()
        _ = assembler.push(YAPPEncoder.notReady(reason: "Disk full").prefix(3))
        XCTAssertFalse(assembler.isEmpty)
        assembler.reset()
        XCTAssertTrue(assembler.isEmpty)
        XCTAssertEqual(assembler.push(Data("A".utf8)), [.text(Data("A".utf8))])
    }
}
