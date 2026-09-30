import XCTest
@testable import AXTerm

/// Cutting a session's byte stream back into YAPP frames.
///
/// The failure this exists for is ordinary: a 254-byte data block over a
/// 128-byte paclen arrives as two I-frames, and `YAPPProtocol` NAKs anything
/// short. These pin every frame kind, split at every byte, and joined.
final class YAPPFrameAssemblerTests: XCTestCase {

    private let yapp = YAPPProtocol()

    private var everyFrame: [Data] {
        [
            yapp.encodeSendInit(),
            yapp.encodeReceiveInit(),
            yapp.encodeHeader(fileName: "roster.bin", fileSize: 4096),
            yapp.encodeDataBlock(data: Data((0..<250).map { UInt8($0 & 0xFF) })),
            yapp.encodeDataBlock(data: Data([0x01, 0x02, 0x03, 0x04, 0x06, 0x15, 0x18])),
            yapp.encodeEndFile(),
            yapp.encodeEndTransmission(),
            yapp.encodeAck(),
            yapp.encodeNak(),
            yapp.encodeCancel()
        ]
    }

    func testEachFrameArrivingWholeComesOutWhole() {
        for frame in everyFrame {
            var assembler = YAPPFrameAssembler()
            XCTAssertEqual(assembler.push(frame), [.frame(frame)], "\(Array(frame.prefix(3)))")
            XCTAssertTrue(assembler.isEmpty)
        }
    }

    func testEachFrameSplitAtEveryByteComesOutOnceAndWhole() {
        for frame in everyFrame where frame.count > 1 {
            for cut in 1..<frame.count {
                var assembler = YAPPFrameAssembler()
                XCTAssertEqual(assembler.push(frame.prefix(cut)), [],
                               "nothing until the frame is complete (cut \(cut))")
                XCTAssertEqual(assembler.push(frame.dropFirst(cut)), [.frame(frame)],
                               "cut at \(cut)")
            }
        }
    }

    func testFramesJoinedInOneDeliveryComeOutSeparately() {
        var assembler = YAPPFrameAssembler()
        let joined = everyFrame.reduce(Data(), +)
        XCTAssertEqual(assembler.push(joined), everyFrame.map { .frame($0) })
    }

    func testByteAtATimeDeliveryStillAssemblesEverything() {
        var assembler = YAPPFrameAssembler()
        var pieces: [YAPPFrameAssembler.Piece] = []
        for byte in everyFrame.reduce(Data(), +) {
            pieces += assembler.push(Data([byte]))
        }
        XCTAssertEqual(pieces, everyFrame.map { .frame($0) })
    }

    func testTypedTextIsHandedBackAsText() {
        var assembler = YAPPFrameAssembler()
        let ack = yapp.encodeAck()
        XCTAssertEqual(assembler.push(Data("A\r".utf8) + ack + Data("hi".utf8)),
                       [.text(Data("A\r".utf8)), .frame(ack), .text(Data("hi".utf8))],
                       "a caller whose software has no YAPP can still type A")
    }

    func testABlockAnnouncingAnImpossibleSizeIsNotWaitedFor() {
        var assembler = YAPPFrameAssembler()
        let lie = Data([YAPPControlChar.stx.rawValue, 0xFF, 0xFF, 0x00])
        XCTAssertEqual(assembler.push(lie), [.malformed],
                       "64 KB that will never come would hang the transfer")
        XCTAssertTrue(assembler.isEmpty)
    }

    func testTheLargestRealisticBlockIsAccepted() {
        var assembler = YAPPFrameAssembler()
        let block = yapp.encodeDataBlock(data: Data(repeating: 0x55,
                                                    count: YAPPFrameAssembler.maxBlockBytes))
        XCTAssertEqual(assembler.push(block), [.frame(block)])
    }
}
