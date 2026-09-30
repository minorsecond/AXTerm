//
//  YAPPProtocolTests.swift
//  AXTermTests
//
//  YAPP as the published frame table defines it (WA7MBL, with the YAPPC
//  checksum extension): the bytes of every frame, the stream parser that
//  splits them back out of arbitrary I-frame boundaries, and both halves of
//  the handshake. A YAPP that only talks to itself is worthless on the air,
//  so the encoder tests pin exact bytes rather than round trips.
//

import XCTest
@testable import AXTerm

final class YAPPProtocolTests: XCTestCase {

    // MARK: - Frame bytes, straight from the table

    func testHandshakeFramesMatchTheFrameTable() {
        XCTAssertEqual(YAPPEncoder.sendInit(), Data([0x05, 0x01]), "SI is ENQ 01")
        XCTAssertEqual(YAPPEncoder.receiveReady(), Data([0x06, 0x01]), "RR is ACK 01")
        XCTAssertEqual(YAPPEncoder.receiveFile(), Data([0x06, 0x02]), "RF is ACK 02")
        XCTAssertEqual(YAPPEncoder.ackEndFile(), Data([0x06, 0x03]), "AF is ACK 03")
        XCTAssertEqual(YAPPEncoder.ackEndTransmission(), Data([0x06, 0x04]), "AT is ACK 04")
        XCTAssertEqual(YAPPEncoder.ackCancel(), Data([0x06, 0x05]), "CA is ACK 05")
        XCTAssertEqual(YAPPEncoder.receiveFileWithChecksum(), Data([0x06, 0x06]), "RT is ACK ACK")
        XCTAssertEqual(YAPPEncoder.endFile(), Data([0x03, 0x01]), "EF is ETX 01")
        XCTAssertEqual(YAPPEncoder.endTransmission(), Data([0x04, 0x01]), "ET is EOT 01")
    }

    func testHeaderIsSOHLengthNameNulSizeNul() {
        let frame = YAPPEncoder.header(name: "TEST.TXT", size: 1234)
        let payload = Array("TEST.TXT".utf8) + [0] + Array("1234".utf8) + [0]
        XCTAssertEqual(frame, Data([0x01, UInt8(payload.count)] + payload))
    }

    func testHeaderReplacesNonASCIIAndStaysWithinOneLengthByte() {
        let frame = YAPPEncoder.header(name: "café.txt", size: 5)
        XCTAssertEqual(Array(frame.prefix(2)), [0x01, 11])
        XCTAssertEqual(String(decoding: frame.dropFirst(2).prefix(8), as: UTF8.self), "caf_.txt")

        let long = String(repeating: "N", count: 400) + ".zip"
        let longFrame = YAPPEncoder.header(name: long, size: 99)
        XCTAssertEqual(Int(longFrame[1]), longFrame.count - 2, "the length byte covers the payload")
        XCTAssertLessThanOrEqual(longFrame.count - 2, 255)
        var parser = YAPPFrameParser()
        guard case .header(let name, let size)? = parser.feed(longFrame).first else {
            return XCTFail("a shortened header still parses")
        }
        XCTAssertTrue(name.hasSuffix(".zip"), "the extension survives shortening")
        XCTAssertEqual(size, 99)
    }

    func testDataBlockIsSTXLengthData() {
        XCTAssertEqual(YAPPEncoder.data(Data([0xAA, 0xBB]), checksum: false), Data([0x02, 0x02, 0xAA, 0xBB]))
    }

    func testDataBlockOf256BytesIsSentWithLengthZero() {
        let block = Data(repeating: 0x41, count: 256)
        let frame = YAPPEncoder.data(block, checksum: false)
        XCTAssertEqual(frame[1], 0)
        XCTAssertEqual(frame.count, 258)
    }

    func testYAPPCChecksumIsTheSumOfDataBytesModulo256() {
        let block = Data([0xFF, 0x02, 0x01])
        XCTAssertEqual(YAPPEncoder.checksum(block), 0x02, "0xFF+0x02+0x01 wraps to 0x02")
        XCTAssertEqual(YAPPEncoder.data(block, checksum: true), Data([0x02, 0x03, 0xFF, 0x02, 0x01, 0x02]))
    }

    func testNotReadyAndCancelCarryACountedReason() {
        XCTAssertEqual(YAPPEncoder.notReady(reason: "No"), Data([0x15, 0x02, 0x4E, 0x6F]))
        XCTAssertEqual(YAPPEncoder.cancel(reason: ""), Data([0x18, 0x00]))
    }

    // MARK: - Parser

    func testParserReadsEveryFrameKind() {
        var parser = YAPPFrameParser()
        var stream = Data()
        stream += YAPPEncoder.sendInit()
        stream += YAPPEncoder.receiveReady()
        stream += YAPPEncoder.header(name: "A.BIN", size: 3)
        stream += YAPPEncoder.receiveFile()
        stream += YAPPEncoder.receiveFileWithChecksum()
        stream += YAPPEncoder.data(Data([1, 2, 3]), checksum: false)
        stream += YAPPEncoder.endFile()
        stream += YAPPEncoder.ackEndFile()
        stream += YAPPEncoder.endTransmission()
        stream += YAPPEncoder.ackEndTransmission()
        stream += YAPPEncoder.notReady(reason: "busy")
        stream += Data([0x15, 0x06, 0x52, 0x00, 0x31, 0x30, 0x30, 0x00])  // RE: R NUL 100 NUL
        stream += YAPPEncoder.cancel(reason: "bye")
        stream += YAPPEncoder.ackCancel()
        stream += Data([0x10, 0x02, 0x68, 0x69])  // TX "hi"
        XCTAssertEqual(parser.feed(stream), [
            .sendInit, .receiveReady, .header(name: "A.BIN", size: 3), .receiveFile,
            .receiveFileWithChecksum, .data(Data([1, 2, 3])), .endFile, .ackEndFile,
            .endTransmission, .ackEndTransmission, .notReady(reason: "busy"),
            .resume(receivedBytes: 100), .cancel(reason: "bye"), .ackCancel, .text("hi")
        ])
        XCTAssertEqual(parser.pendingByteCount, 0)
    }

    func testParserWaitsForTheRestOfASplitFrame() {
        let block = Data((0..<200).map { UInt8($0 & 0xFF) })
        let frame = YAPPEncoder.data(block, checksum: false)
        var parser = YAPPFrameParser()
        for byte in frame.dropLast() {
            XCTAssertEqual(parser.feed(Data([byte])), [], "nothing until the block is whole")
        }
        XCTAssertEqual(parser.feed(Data([frame.last!])), [.data(block)])
    }

    func testParserSplitsFramesThatShareAPacket() {
        var parser = YAPPFrameParser()
        let two = YAPPEncoder.data(Data([9]), checksum: false) + YAPPEncoder.endFile()
        XCTAssertEqual(parser.feed(two), [.data(Data([9])), .endFile])
    }

    func testParserChecksChecksumsOnlyWhenTold() {
        let good = YAPPEncoder.data(Data([1, 2]), checksum: true)
        var bad = good
        bad[bad.count - 1] ^= 0xFF

        var checking = YAPPFrameParser()
        checking.checksummedData = true
        XCTAssertEqual(checking.feed(good), [.data(Data([1, 2]))])
        XCTAssertEqual(checking.feed(bad), [.corruptData])
    }

    func testParserReportsBytesThatAreNotYAPP() {
        var parser = YAPPFrameParser()
        XCTAssertEqual(parser.feed(Data("hello".utf8)), [.invalid(Data("hello".utf8))])
        XCTAssertEqual(parser.feed(Data([0x06, 0x09])), [.invalid(Data([0x06, 0x09]))], "ACK 09 is no frame")
    }

    func testHeaderWithoutANumericSizeParsesWithNoSize() {
        var parser = YAPPFrameParser()
        let payload = Array("X".utf8) + [0] + Array("abc".utf8) + [0]
        XCTAssertEqual(parser.feed(Data([0x01, UInt8(payload.count)] + payload)), [.header(name: "X", size: nil)])
    }

    // MARK: - Detection

    func testOnlySendInitOpensATransfer() {
        XCTAssertTrue(YAPPProtocol.canHandle(data: Data([0x05, 0x01])))
        XCTAssertTrue(YAPPProtocol.canHandle(data: Data([0x05, 0x01, 0x41])))
        XCTAssertFalse(YAPPProtocol.canHandle(data: Data([0x01, 0x01])), "SOH 01 was this file's old, invented SI")
        XCTAssertFalse(YAPPProtocol.canHandle(data: Data([0x06, 0x01])))
        XCTAssertFalse(YAPPProtocol.canHandle(data: Data([0x05])))
        XCTAssertFalse(YAPPProtocol.canHandle(data: Data()))
    }

    func testASendInitPacketIsExactlyTheTwoBytes() {
        XCTAssertTrue(YAPPProtocol.isSendInitPacket(Data([0x05, 0x01])))
        XCTAssertFalse(YAPPProtocol.isSendInitPacket(Data([0x05, 0x01, 0x0D])))
        XCTAssertFalse(YAPPProtocol.isSendInitPacket(Data("A\u{05}\u{01}".utf8)))
    }

    // MARK: - Sender

    func testSenderWalksTheHandshake() throws {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        yapp.blockSize = 4
        try yapp.startSending(fileName: "F.BIN", fileData: Data([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(spy.sent.last, YAPPEncoder.sendInit())
        XCTAssertEqual(yapp.state, .waitingForAccept)

        yapp.handleIncomingData(YAPPEncoder.receiveReady())
        XCTAssertEqual(spy.sent.last, YAPPEncoder.header(name: "F.BIN", size: 6))

        yapp.handleIncomingData(YAPPEncoder.receiveFile())
        XCTAssertEqual(Array(spy.sent.suffix(3)), [
            YAPPEncoder.data(Data([1, 2, 3, 4]), checksum: false),
            YAPPEncoder.data(Data([5, 6]), checksum: false),
            YAPPEncoder.endFile()
        ], "blocks stream with no per-block acknowledgment, then EF")
        XCTAssertEqual(yapp.state, .waitingForAck)

        yapp.handleIncomingData(YAPPEncoder.ackEndFile())
        XCTAssertEqual(spy.sent.last, YAPPEncoder.endTransmission())
        XCTAssertNil(spy.completion)

        yapp.handleIncomingData(YAPPEncoder.ackEndTransmission())
        XCTAssertEqual(yapp.state, .completed)
        XCTAssertEqual(spy.completion?.ok, true)
        XCTAssertEqual(yapp.bytesTransferred, 6)
    }

    func testSenderAddsChecksumsWhenTheReceiverAnswersRT() throws {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        try yapp.startSending(fileName: "F", fileData: Data([7, 8]))
        yapp.handleIncomingData(YAPPEncoder.receiveReady())
        yapp.handleIncomingData(YAPPEncoder.receiveFileWithChecksum())
        XCTAssertTrue(spy.sent.contains(YAPPEncoder.data(Data([7, 8]), checksum: true)))
    }

    func testSenderResumesFromTheOffsetInRE() throws {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        yapp.blockSize = 10
        try yapp.startSending(fileName: "F", fileData: Data(0..<20))
        yapp.handleIncomingData(YAPPEncoder.receiveReady())
        yapp.handleIncomingData(Data([0x15, 0x05, 0x52, 0x00, 0x31, 0x35, 0x00]))  // RE at 15
        XCTAssertTrue(spy.sent.contains(YAPPEncoder.data(Data(15..<20), checksum: false)))
        XCTAssertFalse(spy.sent.contains(YAPPEncoder.data(Data(0..<10), checksum: false)))
    }

    func testSenderStopsWhenRefusedWithNR() throws {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        try yapp.startSending(fileName: "F", fileData: Data([1]))
        yapp.handleIncomingData(YAPPEncoder.receiveReady())
        yapp.handleIncomingData(YAPPEncoder.notReady(reason: "Disk full"))
        XCTAssertEqual(spy.completion?.ok, false)
        XCTAssertEqual(spy.completion?.error, "The other station refused the file: Disk full")
        guard case .failed = yapp.state else { return XCTFail("refused is a failure") }
    }

    func testSenderPacesBlocksToTheLink() throws {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        yapp.blockSize = 2
        var room = 1
        yapp.readyForData = {
            guard room > 0 else { return false }
            room -= 1
            return true
        }
        try yapp.startSending(fileName: "F", fileData: Data([1, 2, 3, 4, 5, 6]))
        yapp.handleIncomingData(YAPPEncoder.receiveReady())
        yapp.handleIncomingData(YAPPEncoder.receiveFile())
        XCTAssertEqual(spy.dataBlocks, 1, "one block while the link had room for one")
        room = 1
        yapp.pumpData()
        XCTAssertEqual(spy.dataBlocks, 2)
        room = 10
        yapp.pumpData()
        XCTAssertEqual(spy.dataBlocks, 3)
        XCTAssertEqual(spy.sent.last, YAPPEncoder.endFile())
    }

    func testPauseHoldsBlocksAndResumeSendsTheRest() throws {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        yapp.blockSize = 1
        var room = 1
        yapp.readyForData = { defer { room = max(0, room - 1) }; return room > 0 }
        try yapp.startSending(fileName: "F", fileData: Data([1, 2, 3]))
        yapp.handleIncomingData(YAPPEncoder.receiveReady())
        yapp.handleIncomingData(YAPPEncoder.receiveFile())
        yapp.pause()
        XCTAssertEqual(yapp.state, .paused)
        room = 10
        yapp.pumpData()
        XCTAssertEqual(spy.dataBlocks, 1, "paused means no blocks, room or not")
        yapp.resume()
        XCTAssertEqual(spy.dataBlocks, 3)
        XCTAssertEqual(spy.sent.last, YAPPEncoder.endFile())
    }

    func testLocalCancelSendsCNAndSaysCanceled() throws {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        try yapp.startSending(fileName: "F", fileData: Data([1]))
        yapp.cancel()
        XCTAssertEqual(spy.sent.last, YAPPEncoder.cancel(reason: "Canceled"))
        XCTAssertEqual(yapp.state, .cancelled)
        XCTAssertEqual(spy.completion?.error, "Canceled")
        yapp.handleIncomingData(YAPPEncoder.ackCancel())
        XCTAssertEqual(yapp.senderPhase, .finished)
    }

    func testACancelSettlesWhenCAArrivesOrTheWaitRunsOut() throws {
        let answered = YAPPProtocol()
        var settled = 0
        answered.onCancelSettled = { settled += 1 }
        try answered.startSending(fileName: "F", fileData: Data([1]))
        answered.cancel()
        XCTAssertEqual(settled, 0, "not until CA")
        answered.handleIncomingData(YAPPEncoder.ackCancel())
        XCTAssertEqual(settled, 1)

        let silent = YAPPProtocol()
        silent.cancelAckTimeout = 0.05
        var silentSettled = false
        silent.onCancelSettled = { silentSettled = true }
        try silent.startSending(fileName: "F", fileData: Data([1]))
        silent.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(silentSettled, "no CA within the wait still settles")
    }

    func testAbandonStopsWithoutSendingAnything() throws {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        yapp.responseTimeout = 0.05
        try yapp.startSending(fileName: "F", fileData: Data([1]))
        let sentBefore = spy.sent.count
        yapp.abandon()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(spy.sent.count, sentBefore, "no CN into a link that is gone")
        XCTAssertNil(spy.completion)
        guard case .failed = yapp.state else { return XCTFail("abandoned is failed") }
    }

    func testPeerCancelIsAnsweredWithCA() throws {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        try yapp.startSending(fileName: "F", fileData: Data([1]))
        yapp.handleIncomingData(YAPPEncoder.cancel(reason: "user abort"))
        XCTAssertEqual(spy.sent.last, YAPPEncoder.ackCancel())
        XCTAssertEqual(yapp.state, .cancelled)
        XCTAssertEqual(spy.completion?.error, "Canceled by the other station: user abort")
    }

    func testSenderGivesUpWhenNobodyAnswers() throws {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        yapp.responseTimeout = 0.05
        try yapp.startSending(fileName: "F", fileData: Data([1]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(spy.completion?.ok, false)
        XCTAssertTrue(spy.completion?.error?.hasPrefix("No answer from the other station") == true)
        XCTAssertTrue(spy.sent.last.map { $0.first == 0x18 } == true, "CN goes out on the way")
    }

    func testStartingTwiceIsRefused() throws {
        let yapp = YAPPProtocol()
        try yapp.startSending(fileName: "F", fileData: Data([1]))
        XCTAssertThrowsError(try yapp.startSending(fileName: "G", fileData: Data([2])))
    }

    // MARK: - Receiver

    func testReceiverWalksTheHandshakeAndDeliversTheFile() {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy

        yapp.handleIncomingData(YAPPEncoder.sendInit())
        XCTAssertEqual(spy.sent.last, YAPPEncoder.receiveReady())

        yapp.handleIncomingData(YAPPEncoder.header(name: "R.BIN", size: 3))
        XCTAssertEqual(spy.offered?.fileName, "R.BIN")
        XCTAssertEqual(spy.offered?.fileSize, 3)
        XCTAssertEqual(spy.offered?.protocolType, .yapp)

        yapp.acceptTransfer()
        XCTAssertEqual(spy.sent.last, YAPPEncoder.receiveFile())

        yapp.handleIncomingData(YAPPEncoder.data(Data([9, 8, 7]), checksum: false) + YAPPEncoder.endFile())
        XCTAssertEqual(spy.sent.last, YAPPEncoder.ackEndFile())
        XCTAssertEqual(spy.received?.data, Data([9, 8, 7]))

        yapp.handleIncomingData(YAPPEncoder.endTransmission())
        XCTAssertEqual(spy.sent.last, YAPPEncoder.ackEndTransmission())
        XCTAssertEqual(yapp.state, .completed)
        XCTAssertEqual(spy.completion?.ok, true)
    }

    func testReceiverRefusalSendsNR() {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        yapp.handleIncomingData(YAPPEncoder.sendInit() + YAPPEncoder.header(name: "X", size: 1))
        yapp.rejectTransfer(reason: "Too big")
        XCTAssertEqual(spy.sent.last, YAPPEncoder.notReady(reason: "Too big"))
        XCTAssertEqual(yapp.state, .cancelled)
    }

    func testReceiverFailsAFileThatArrivesShort() {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        yapp.handleIncomingData(YAPPEncoder.sendInit() + YAPPEncoder.header(name: "X", size: 5))
        yapp.acceptTransfer()
        yapp.handleIncomingData(YAPPEncoder.data(Data([1, 2]), checksum: false) + YAPPEncoder.endFile())
        XCTAssertNil(spy.received, "a short file is not handed over")
        XCTAssertEqual(spy.completion?.ok, false)
        XCTAssertEqual(spy.completion?.error, "The file arrived with 2 of the 5 bytes its header announced")
    }

    func testReceiverCancelsWhenAFileOutgrowsItsLimit() {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        yapp.maxReceiveBytes = 3
        yapp.handleIncomingData(YAPPEncoder.sendInit() + YAPPEncoder.header(name: "X", size: 2))
        yapp.acceptTransfer()
        yapp.handleIncomingData(YAPPEncoder.data(Data([1, 2, 3, 4]), checksum: false))
        XCTAssertEqual(spy.sent.last?.first, 0x18, "CN")
        XCTAssertEqual(spy.completion?.error, "The file is larger than this station accepts")
    }

    func testReceiverTreatsGarbageMidTransferAsAProtocolError() {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        yapp.handleIncomingData(YAPPEncoder.sendInit() + YAPPEncoder.header(name: "X", size: 2))
        yapp.acceptTransfer()
        yapp.handleIncomingData(Data("*** Unknown command".utf8))
        XCTAssertEqual(spy.completion?.ok, false)
        XCTAssertEqual(spy.sent.last?.first, 0x18)
    }

    func testReceiverRefusesASecondFileInTheBatchButFinishesTheFirst() {
        let yapp = YAPPProtocol()
        let spy = YAPPSpy()
        yapp.delegate = spy
        yapp.handleIncomingData(YAPPEncoder.sendInit() + YAPPEncoder.header(name: "A", size: 1))
        yapp.acceptTransfer()
        yapp.handleIncomingData(YAPPEncoder.data(Data([1]), checksum: false) + YAPPEncoder.endFile())
        yapp.handleIncomingData(YAPPEncoder.header(name: "B", size: 1))
        XCTAssertEqual(spy.sent.last, YAPPEncoder.notReady(reason: "One file at a time"))
        yapp.handleIncomingData(YAPPEncoder.endTransmission())
        XCTAssertEqual(yapp.state, .completed)
        XCTAssertEqual(spy.received?.metadata.fileName, "A")
    }

    // MARK: - Two ends, one stream

    /// A sender and a receiver wired back to back, with every write cut into
    /// random pieces the way I-frames would cut it. What comes out must be
    /// exactly what went in, for every size that exercises a boundary.
    func testSenderAndReceiverAgreeOverAChoppedStream() throws {
        var generator = SeededGenerator(seed: 0x5A5A)
        let sizes = [0, 1, 124, 125, 126, 256, 257, 1000, 4096]
        for size in sizes {
            let file = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let sender = YAPPProtocol()
            let receiver = YAPPProtocol()
            sender.blockSize = 125
            let pipe = YAPPPipe(sender: sender, receiver: receiver, generator: generator)
            sender.delegate = pipe.senderSide
            receiver.delegate = pipe.receiverSide
            try sender.startSending(fileName: "S\(size).BIN", fileData: file)
            pipe.run()
            XCTAssertEqual(pipe.receiverSide.received?.data, file, "size \(size)")
            XCTAssertEqual(sender.state, .completed, "size \(size)")
            XCTAssertEqual(receiver.state, .completed, "size \(size)")
        }
    }

    func testEveryByteValueSurvivesIncludingControlBytes() throws {
        let file = Data((0..<1024).map { UInt8($0 & 0xFF) })
        let sender = YAPPProtocol()
        let receiver = YAPPProtocol()
        let pipe = YAPPPipe(sender: sender, receiver: receiver, generator: SeededGenerator(seed: 7))
        sender.delegate = pipe.senderSide
        receiver.delegate = pipe.receiverSide
        try sender.startSending(fileName: "ALL.BIN", fileData: file)
        pipe.run()
        XCTAssertEqual(pipe.receiverSide.received?.data, file)
    }

    func testProtocolIdentity() {
        let yapp = YAPPProtocol()
        XCTAssertEqual(yapp.protocolType, .yapp)
        XCTAssertTrue(TransferProtocolType.yapp.requiresConnectedMode)
        XCTAssertFalse(TransferProtocolType.yapp.supportsCompression)
        XCTAssertNil(yapp.isSender)
    }
}

// MARK: - Helpers

/// Records what a YAPP instance asked for.
final class YAPPSpy: FileTransferProtocolDelegate {
    var sent: [Data] = []
    var completion: (ok: Bool, error: String?)?
    var offered: TransferFileMetadata?
    var received: (data: Data, metadata: TransferFileMetadata)?
    var states: [TransferProtocolState] = []
    var onSend: ((Data) -> Void)?
    var autoAccept: ((YAPPProtocol) -> Void)?

    var dataBlocks: Int { sent.filter { $0.first == 0x02 }.count }

    func transferProtocol(_ transfer: FileTransferProtocol, needsToSend data: Data) {
        sent.append(data)
        onSend?(data)
    }
    func transferProtocol(_ transfer: FileTransferProtocol, didUpdateProgress progress: Double, bytesSent: Int) {}
    func transferProtocol(_ transfer: FileTransferProtocol, didComplete successfully: Bool, error: String?) {
        completion = (successfully, error)
    }
    func transferProtocol(_ transfer: FileTransferProtocol, didReceiveFile data: Data, metadata: TransferFileMetadata) {
        received = (data, metadata)
    }
    func transferProtocol(_ transfer: FileTransferProtocol, requestsConfirmation metadata: TransferFileMetadata) {
        offered = metadata
        if let yapp = transfer as? YAPPProtocol { autoAccept?(yapp) }
    }
    func transferProtocol(_ transfer: FileTransferProtocol, stateChanged newState: TransferProtocolState) {
        states.append(newState)
    }
}

/// Carries bytes between two YAPP instances in randomly sized pieces.
final class YAPPPipe {
    let senderSide = YAPPSpy()
    let receiverSide = YAPPSpy()
    private var toReceiver: [Data] = []
    private var toSender: [Data] = []
    private let sender: YAPPProtocol
    private let receiver: YAPPProtocol
    private var generator: SeededGenerator

    init(sender: YAPPProtocol, receiver: YAPPProtocol, generator: SeededGenerator) {
        self.sender = sender
        self.receiver = receiver
        self.generator = generator
        senderSide.onSend = { [unowned self] in self.toReceiver.append($0) }
        receiverSide.onSend = { [unowned self] in self.toSender.append($0) }
        receiverSide.autoAccept = { $0.acceptTransfer() }
    }

    func run() {
        var guardCount = 0
        while (!toReceiver.isEmpty || !toSender.isEmpty) && guardCount < 100_000 {
            guardCount += 1
            if !toReceiver.isEmpty {
                let bytes = toReceiver.removeFirst()
                for piece in chop(bytes) { receiver.handleIncomingData(piece) }
            }
            if !toSender.isEmpty {
                let bytes = toSender.removeFirst()
                for piece in chop(bytes) { sender.handleIncomingData(piece) }
            }
        }
    }

    private func chop(_ data: Data) -> [Data] {
        var pieces: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int.random(in: 1...max(1, data.count), using: &generator)
            let end = min(data.endIndex, index + length)
            pieces.append(data.subdata(in: index..<end))
            index = end
        }
        return pieces
    }
}

/// Deterministic random numbers, so a failing chop can be reproduced.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
