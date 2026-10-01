//
//  YAPPProtocol.swift
//  AXTerm
//
//  YAPP (Yet Another Packet Protocol, WA7MBL 1986) with the YAPPC checksum
//  extension. This is the binary transfer that LinFBB, BPQ, JNOS and most
//  packet terminals speak, so its wire format is copied from the published
//  frame table rather than designed here:
//
//      SI  Send_Init    ENQ 01
//      RR  Rcv_Rdy      ACK 01
//      HD  Send_Hdr     SOH len filename NUL size NUL [date time NUL]
//      RF  Rcv_File     ACK 02
//      RT  Rcv_TPK      ACK ACK            (YAPPC: send checksums)
//      DT  Send_Data    STX len data [checksum]   (len 0 means 256)
//      EF  Send_EOF     ETX 01
//      AF  Ack_EOF      ACK 03
//      ET  Send_EOT     EOT 01
//      AT  Ack_EOT      ACK 04
//      NR  Not_Rdy      NAK len reason
//      RE  Resume       NAK len R NUL received NUL [C NUL]
//      CN  Cancel       CAN len reason
//      CA  Ack_Cancel   ACK 05
//      TX  Text         DLE len text
//      RI  Rcv_Init     ENQ 02 ...        (server mode; not supported here)
//
//  YAPP has no per-block acknowledgment. The sender streams data blocks and
//  leans on AX.25 for delivery; the only handshakes are at the start (SI/RR,
//  HD/RF) and the end (EF/AF, ET/AT). The YAPPC checksum is the sum of the
//  data bytes modulo 256, and is only sent after the receiver asked for it
//  with RT.
//
//  Frames arrive as a byte stream: one I-frame can hold part of a block, or
//  the end of one block and the start of the next. `YAPPFrameParser` buffers
//  and splits on the length bytes, so nothing here assumes one frame per
//  packet.
//

import Foundation

// MARK: - Control characters

/// The control bytes the YAPP frame table uses.
nonisolated enum YAPPControlChar: UInt8 {
    case soh = 0x01  // Header
    case stx = 0x02  // Data block
    case etx = 0x03  // End of file
    case eot = 0x04  // End of transmission
    case enq = 0x05  // Send init
    case ack = 0x06  // Acknowledgments (second byte says which)
    case dle = 0x10  // Text
    case nak = 0x15  // Not ready / resume
    case can = 0x18  // Cancel
}

// MARK: - Frames

/// One decoded YAPP frame.
nonisolated enum YAPPFrame: Equatable, Sendable {
    case sendInit
    case receiveReady
    /// `size` is nil when the header's size field is not a number.
    case header(name: String, size: Int?)
    case receiveFile
    case receiveFileWithChecksum
    case data(Data)
    /// A YAPPC block whose checksum did not add up.
    case corruptData
    case endFile
    case ackEndFile
    case endTransmission
    case ackEndTransmission
    case notReady(reason: String)
    case resume(receivedBytes: Int)
    case cancel(reason: String)
    case ackCancel
    case text(String)
    /// Bytes that are not a YAPP frame at all.
    case invalid(Data)
}

// MARK: - Encoding

/// Builds frames exactly as the frame table lays them out.
nonisolated enum YAPPEncoder {
    static func sendInit() -> Data { Data([0x05, 0x01]) }
    static func receiveReady() -> Data { Data([0x06, 0x01]) }
    static func receiveFile() -> Data { Data([0x06, 0x02]) }
    static func receiveFileWithChecksum() -> Data { Data([0x06, 0x06]) }
    static func ackEndFile() -> Data { Data([0x06, 0x03]) }
    static func ackEndTransmission() -> Data { Data([0x06, 0x04]) }
    static func ackCancel() -> Data { Data([0x06, 0x05]) }
    static func endFile() -> Data { Data([0x03, 0x01]) }
    static func endTransmission() -> Data { Data([0x04, 0x01]) }

    /// HD. The whole payload has to fit its one length byte, so a long name
    /// is shortened from the front of its base name, keeping the extension:
    /// the extension is what tells the receiver what the file is.
    static func header(name: String, size: Int) -> Data {
        let sizeBytes = Array(String(max(0, size)).utf8)
        let budget = 255 - sizeBytes.count - 2
        var nameBytes = asciiName(name)
        if nameBytes.count > budget {
            let ext = (name as NSString).pathExtension
            let extBytes = ext.isEmpty ? [] : Array(("." + ext).utf8)
            let keep = max(1, budget - extBytes.count)
            nameBytes = Array(nameBytes.prefix(keep)) + (extBytes.count < budget ? extBytes : [])
            nameBytes = Array(nameBytes.prefix(budget))
        }
        var payload = nameBytes
        payload.append(0)
        payload.append(contentsOf: sizeBytes)
        payload.append(0)
        return Data([0x01, UInt8(payload.count)] + payload)
    }

    /// DT. `data` must be 1...256 bytes; 256 is sent as length 0.
    static func data(_ data: Data, checksum: Bool) -> Data {
        precondition(!data.isEmpty && data.count <= 256, "a YAPP block holds 1 to 256 bytes")
        var frame = Data([0x02, UInt8(data.count == 256 ? 0 : data.count)])
        frame.append(data)
        if checksum { frame.append(Self.checksum(data)) }
        return frame
    }

    static func notReady(reason: String) -> Data { counted(0x15, reason) }
    static func cancel(reason: String) -> Data { counted(0x18, reason) }

    /// The YAPPC checksum: the data bytes summed modulo 256.
    static func checksum(_ data: Data) -> UInt8 {
        data.reduce(UInt8(0)) { $0 &+ $1 }
    }

    /// NAK and CAN carry an optional ASCII reason behind a length byte.
    private static func counted(_ lead: UInt8, _ text: String) -> Data {
        let bytes = Array(asciiName(text).prefix(255))
        return Data([lead, UInt8(bytes.count)] + bytes)
    }

    /// YAPP predates any character set but ASCII. Anything else becomes an
    /// underscore rather than disappearing, so two names that differ only in
    /// accented letters stay two names.
    private static func asciiName(_ text: String) -> [UInt8] {
        text.unicodeScalars.map { scalar in
            (scalar.value >= 0x20 && scalar.value < 0x7F) ? UInt8(scalar.value) : UInt8(ascii: "_")
        }
    }
}

// MARK: - Parsing

/// Splits a YAPP byte stream into frames.
///
/// Holds partial frames until the rest arrives. `checksummedData` has to be
/// set by whoever knows the transfer negotiated YAPPC, because a data block's
/// length byte does not say whether a checksum follows it.
nonisolated struct YAPPFrameParser: Sendable {
    var checksummedData = false
    private var buffer: [UInt8] = []

    /// Bytes still waiting for the rest of their frame.
    var pendingByteCount: Int { buffer.count }

    mutating func feed(_ data: Data) -> [YAPPFrame] {
        buffer.append(contentsOf: data)
        var frames: [YAPPFrame] = []
        while let (frame, used) = nextFrame() {
            frames.append(frame)
            buffer.removeFirst(used)
        }
        return frames
    }

    private func nextFrame() -> (YAPPFrame, Int)? {
        guard let lead = buffer.first else { return nil }
        switch lead {
        case 0x05, 0x06, 0x03, 0x04:
            guard buffer.count >= 2 else { return nil }
            return (twoByteFrame(lead, buffer[1]), 2)
        case 0x01, 0x15, 0x18, 0x10:
            guard buffer.count >= 2 else { return nil }
            let length = Int(buffer[1])
            guard buffer.count >= 2 + length else { return nil }
            let body = Array(buffer[2..<(2 + length)])
            return (countedFrame(lead, body), 2 + length)
        case 0x02:
            guard buffer.count >= 2 else { return nil }
            let length = buffer[1] == 0 ? 256 : Int(buffer[1])
            let total = 2 + length + (checksummedData ? 1 : 0)
            guard buffer.count >= total else { return nil }
            let block = Data(buffer[2..<(2 + length)])
            if checksummedData, buffer[2 + length] != YAPPEncoder.checksum(block) {
                return (.corruptData, total)
            }
            return (.data(block), total)
        default:
            // Not a frame. Everything held goes back as one lump: once the
            // stream has lost its framing nothing after this point can be
            // trusted to start on a frame boundary either.
            return (.invalid(Data(buffer)), buffer.count)
        }
    }

    private func twoByteFrame(_ lead: UInt8, _ code: UInt8) -> YAPPFrame {
        switch (lead, code) {
        case (0x05, 0x01): return .sendInit
        case (0x06, 0x01): return .receiveReady
        case (0x06, 0x02): return .receiveFile
        case (0x06, 0x03): return .ackEndFile
        case (0x06, 0x04): return .ackEndTransmission
        case (0x06, 0x05): return .ackCancel
        case (0x06, 0x06): return .receiveFileWithChecksum
        // The table gives EF and ET a second byte of 01, but nothing else can
        // start with ETX or EOT, so any second byte is read the same way.
        case (0x03, _): return .endFile
        case (0x04, _): return .endTransmission
        default: return .invalid(Data([lead, code]))
        }
    }

    private func countedFrame(_ lead: UInt8, _ body: [UInt8]) -> YAPPFrame {
        let text = String(decoding: body, as: UTF8.self)
        switch lead {
        case 0x01:
            let fields = body.split(separator: 0, omittingEmptySubsequences: false)
            guard let first = fields.first, !first.isEmpty else { return .invalid(Data([lead] + body)) }
            let name = String(decoding: first, as: UTF8.self)
            let sizeText = fields.count > 1
                ? String(decoding: fields[1], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                : ""
            return .header(name: name, size: Int(sizeText))
        case 0x15:
            // RE is a NAK whose text starts with "R" NUL.
            if body.count >= 2, body[0] == UInt8(ascii: "R"), body[1] == 0 {
                let fields = body.dropFirst(2).split(separator: 0, omittingEmptySubsequences: false)
                let received = fields.first.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
                return .resume(receivedBytes: received)
            }
            return .notReady(reason: text)
        case 0x18:
            return .cancel(reason: text)
        default:
            return .text(text)
        }
    }
}

// MARK: - Phases

/// Where the sending side is in the handshake.
nonisolated enum YAPPSenderPhase: Equatable, Sendable {
    case idle
    case awaitingReceiveReady
    case awaitingReceiveFile
    case streaming
    case awaitingEndFileAck
    case awaitingEndTransmissionAck
    case awaitingCancelAck
    case finished
}

/// Where the receiving side is in the handshake.
nonisolated enum YAPPReceiverPhase: Equatable, Sendable {
    case idle
    case awaitingHeader
    case awaitingDecision
    case receiving
    case awaitingEndTransmission
    case awaitingCancelAck
    case finished
}

// MARK: - YAPP Protocol

// `@unchecked Sendable`: every entry point runs on the main thread and the
// timeout timers are scheduled on the main run loop, so the mutable state is
// confined in practice. The same convention the rest of the transmission
// layer runs on.
nonisolated final class YAPPProtocol: FileTransferProtocol, @unchecked Sendable {
    let protocolType: TransferProtocolType = .yapp

    weak var delegate: FileTransferProtocolDelegate?

    private(set) var state: TransferProtocolState = .idle
    private(set) var bytesTransferred: Int = 0
    private(set) var totalBytes: Int = 0

    // MARK: Configuration

    /// Data bytes per DT block. Kept a few bytes under the common paclen of
    /// 128 so each block, with its two header bytes and optional checksum,
    /// fits one I-frame: some older receivers read one block per packet.
    var blockSize: Int = 125 {
        didSet { blockSize = max(1, min(256, blockSize)) }
    }

    /// How long to wait for the other side to answer a handshake frame, or
    /// for the next data block, before giving up.
    var responseTimeout: TimeInterval = 120

    /// How long to wait for CA after sending CN before calling the cancel done.
    var cancelAckTimeout: TimeInterval = 10

    /// The largest file this side will take, whatever the header says.
    var maxReceiveBytes: Int = 16 * 1024 * 1024

    /// Asked before each data block. Nil streams the whole file at once and
    /// leaves pacing to the link's own queue; a caller that wants accurate
    /// progress and a cancel that takes effect promptly answers false while
    /// its link is busy, and calls `pumpData()` when it has room again.
    var readyForData: (() -> Bool)?

    /// Called once a cancel is settled: the other side answered CA, or the
    /// wait for it ran out. Until then the stream still belongs to this
    /// transfer, because the CA is on its way.
    var onCancelSettled: (() -> Void)?

    // MARK: State

    private(set) var senderPhase: YAPPSenderPhase = .idle
    private(set) var receiverPhase: YAPPReceiverPhase = .idle
    private var parser = YAPPFrameParser()
    private var timer: Timer?
    private var isPaused = false

    // Sender
    private var fileName = ""
    private var fileData = Data()
    private var sendOffset = 0
    private var sendChecksums = false

    // Receiver
    private var receivedData = Data()
    private(set) var receivedFileName = ""
    private(set) var announcedSize: Int?
    /// Set once the finished file has been checked: true if it was handed
    /// over, false if it arrived the wrong size.
    private var fileDelivery: Bool?

    /// Whether this instance is sending (true) or receiving (false). Nil
    /// until one side starts.
    var isSender: Bool? {
        if senderPhase != .idle { return true }
        if receiverPhase != .idle { return false }
        return nil
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Detection

    /// Whether `data` opens a YAPP transfer: it starts with SI (ENQ 01).
    /// SI is the only frame a transfer can begin with, so nothing else here
    /// is taken as the start of one.
    static func canHandle(data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let bytes = Array(data.prefix(2))
        return bytes[0] == YAPPControlChar.enq.rawValue && bytes[1] == 0x01
    }

    /// Whether a whole delivered packet is exactly SI.
    ///
    /// Used to spot a transfer arriving on a terminal session. A BBS sends
    /// SI as a packet of its own, and ENQ never appears in text, so a packet
    /// holding those two bytes and nothing else is a transfer starting.
    /// Anything longer, or those bytes inside other text, is left alone.
    static func isSendInitPacket(_ data: Data) -> Bool {
        data.count == 2 && canHandle(data: data)
    }

    // MARK: Sending

    func startSending(fileName: String, fileData: Data) throws {
        guard senderPhase == .idle, receiverPhase == .idle else {
            throw FileTransferError.invalidState(expected: "idle", actual: String(describing: state))
        }
        self.fileName = fileName
        self.fileData = fileData
        totalBytes = fileData.count
        bytesTransferred = 0
        sendOffset = 0
        senderPhase = .awaitingReceiveReady
        setState(.waitingForAccept)
        send(YAPPEncoder.sendInit())
        armTimer(responseTimeout)
    }

    /// Sends as many data blocks as the link has room for.
    func pumpData() {
        guard senderPhase == .streaming, !isPaused else { return }
        while senderPhase == .streaming, !isPaused, readyForData?() ?? true {
            guard sendOffset < fileData.count else {
                senderPhase = .awaitingEndFileAck
                setState(.waitingForAck)
                send(YAPPEncoder.endFile())
                armTimer(responseTimeout)
                return
            }
            let end = min(sendOffset + blockSize, fileData.count)
            let block = fileData.subdata(in: sendOffset..<end)
            send(YAPPEncoder.data(block, checksum: sendChecksums))
            sendOffset = end
            bytesTransferred = end
            delegate?.transferProtocol(self, didUpdateProgress: progress, bytesSent: bytesTransferred)
        }
        // Waiting on the link is not waiting on the peer: the timer only runs
        // for handshakes, and the link's own retries cover a stalled channel.
    }

    func handleAck(data: Data) { handleIncomingData(data) }
    func handleNak(data: Data) { handleIncomingData(data) }

    func pause() {
        guard senderPhase == .streaming, !isPaused else { return }
        isPaused = true
        setState(.paused)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        setState(.transferring)
        pumpData()
    }

    /// Stops the transfer and tells the other side with CN.
    func cancel() {
        guard !state.isTerminal else { return }
        let wasActive = senderPhase != .idle || receiverPhase != .idle
        if senderPhase != .idle { senderPhase = .awaitingCancelAck }
        if receiverPhase != .idle { receiverPhase = .awaitingCancelAck }
        setState(.cancelled)
        if wasActive {
            send(YAPPEncoder.cancel(reason: "Canceled"))
            armTimer(cancelAckTimeout)
        }
        delegate?.transferProtocol(self, didComplete: false, error: "Canceled")
    }

    /// Stops everything without a word to the other side, for when there is
    /// no longer a link to say it on. No delegate calls follow.
    func abandon() {
        timer?.invalidate()
        timer = nil
        if senderPhase != .idle { senderPhase = .finished }
        if receiverPhase != .idle { receiverPhase = .finished }
        if !state.isTerminal { state = .failed(reason: "The link was lost") }
    }

    // MARK: Receiving

    @discardableResult
    func handleIncomingData(_ data: Data) -> Bool {
        let frames = parser.feed(data)
        for frame in frames {
            handle(frame)
        }
        return !frames.isEmpty || parser.pendingByteCount > 0
    }

    func acceptTransfer() {
        guard receiverPhase == .awaitingDecision else { return }
        receiverPhase = .receiving
        receivedData = Data()
        bytesTransferred = 0
        setState(.transferring)
        send(YAPPEncoder.receiveFile())
        armTimer(responseTimeout)
    }

    func rejectTransfer(reason: String) {
        guard receiverPhase == .awaitingDecision else { return }
        receiverPhase = .finished
        timer?.invalidate()
        setState(.cancelled)
        send(YAPPEncoder.notReady(reason: reason))
    }

    // MARK: Frame handling

    private func handle(_ frame: YAPPFrame) {
        // A cancel from the other side ends things from any phase.
        if case .cancel(let reason) = frame {
            send(YAPPEncoder.ackCancel())
            let text = reason.isEmpty ? "Canceled by the other station" : "Canceled by the other station: \(reason)"
            finish(.cancelled, error: text)
            return
        }
        if case .text = frame { return }  // TX is informational only.

        if senderPhase != .idle {
            handleAsSender(frame)
        } else {
            handleAsReceiver(frame)
        }
    }

    private func handleAsSender(_ frame: YAPPFrame) {
        switch (senderPhase, frame) {
        case (.awaitingReceiveReady, .receiveReady):
            senderPhase = .awaitingReceiveFile
            send(YAPPEncoder.header(name: fileName, size: totalBytes))
            armTimer(responseTimeout)

        case (.awaitingReceiveFile, .receiveFile), (.awaitingReceiveFile, .receiveFileWithChecksum):
            sendChecksums = frame == .receiveFileWithChecksum
            startStreaming(from: 0)

        case (.awaitingReceiveFile, .resume(let received)):
            // The receiver already holds the first `received` bytes. RE is
            // only sent by receivers that keep partial files; take it at its
            // word, clamped to what exists.
            startStreaming(from: min(max(0, received), fileData.count))

        case (.awaitingReceiveReady, .notReady(let reason)), (.awaitingReceiveFile, .notReady(let reason)):
            finish(.failed(reason: refusal(reason)), error: refusal(reason))

        case (.awaitingEndFileAck, .ackEndFile):
            senderPhase = .awaitingEndTransmissionAck
            send(YAPPEncoder.endTransmission())
            armTimer(responseTimeout)

        case (.awaitingEndTransmissionAck, .ackEndTransmission):
            senderPhase = .finished
            timer?.invalidate()
            setState(.completed)
            delegate?.transferProtocol(self, didComplete: true, error: nil)

        case (.awaitingCancelAck, .ackCancel):
            senderPhase = .finished
            timer?.invalidate()
            onCancelSettled?()

        case (.awaitingEndTransmissionAck, .invalid):
            // The receiver acknowledged end of file, so it has every byte.
            // A line printed now instead of the end-of-transmission ack is a
            // receiver speaking early, not a failed transfer (AXTerm's own
            // mailbox did this until 2026-10-01).
            senderPhase = .finished
            timer?.invalidate()
            setState(.completed)
            delegate?.transferProtocol(self, didComplete: true, error: nil)

        case (_, .invalid):
            protocolError("The other station sent something that is not YAPP")

        default:
            // A repeated or out-of-place handshake frame. The link delivered
            // it once already or the peer is ahead of us; neither is worth
            // tearing a transfer down for.
            break
        }
    }

    private func handleAsReceiver(_ frame: YAPPFrame) {
        switch (receiverPhase, frame) {
        case (.idle, .sendInit), (.awaitingHeader, .sendInit):
            receiverPhase = .awaitingHeader
            send(YAPPEncoder.receiveReady())
            armTimer(responseTimeout)

        case (.awaitingHeader, .header(let name, let size)):
            receivedFileName = name
            announcedSize = size
            totalBytes = size ?? 0
            receiverPhase = .awaitingDecision
            timer?.invalidate()
            delegate?.transferProtocol(self, requestsConfirmation: TransferFileMetadata(
                fileName: name, fileSize: size ?? 0, protocolType: .yapp))

        case (.receiving, .data(let block)):
            guard receivedData.count + block.count <= maxReceiveBytes else {
                protocolError("The file is larger than this station accepts")
                return
            }
            receivedData.append(block)
            bytesTransferred = receivedData.count
            delegate?.transferProtocol(self, didUpdateProgress: progress, bytesSent: bytesTransferred)
            armTimer(responseTimeout)

        case (.receiving, .corruptData):
            protocolError("A data block failed its checksum")

        case (.receiving, .endFile):
            receiverPhase = .awaitingEndTransmission
            send(YAPPEncoder.ackEndFile())
            deliverFile()
            armTimer(responseTimeout)

        case (.receiving, .endTransmission), (.awaitingEndTransmission, .endTransmission):
            send(YAPPEncoder.ackEndTransmission())
            receiverPhase = .finished
            timer?.invalidate()
            let ok = deliverFile()
            if ok {
                setState(.completed)
                delegate?.transferProtocol(self, didComplete: true, error: nil)
            }

        case (.awaitingEndTransmission, .header):
            // A second file in the same batch. One file per transfer here;
            // the sender answers NR by moving on to ET.
            send(YAPPEncoder.notReady(reason: "One file at a time"))

        case (.awaitingCancelAck, .ackCancel):
            receiverPhase = .finished
            timer?.invalidate()
            onCancelSettled?()

        case (.receiving, .invalid), (.awaitingHeader, .invalid), (.awaitingEndTransmission, .invalid):
            protocolError("The other station sent something that is not YAPP")

        default:
            break
        }
    }

    // MARK: Helpers

    private func startStreaming(from offset: Int) {
        timer?.invalidate()
        sendOffset = offset
        bytesTransferred = offset
        senderPhase = .streaming
        setState(.transferring)
        pumpData()
    }

    /// Hands the finished file over once. Returns false (and fails the
    /// transfer) when it arrived shorter or longer than its header said.
    @discardableResult
    private func deliverFile() -> Bool {
        if let fileDelivery { return fileDelivery }
        if let announced = announcedSize, announced != receivedData.count {
            fileDelivery = false
            let reason = "The file arrived with \(receivedData.count) of the \(announced) bytes its header announced"
            finish(.failed(reason: reason), error: reason)
            return false
        }
        fileDelivery = true
        let metadata = TransferFileMetadata(
            fileName: receivedFileName, fileSize: receivedData.count, protocolType: .yapp)
        delegate?.transferProtocol(self, didReceiveFile: receivedData, metadata: metadata)
        return true
    }

    private func refusal(_ reason: String) -> String {
        reason.isEmpty ? "The other station refused the file" : "The other station refused the file: \(reason)"
    }

    /// Ends a transfer that went wrong, telling the other side with CN.
    private func protocolError(_ reason: String) {
        guard !state.isTerminal else { return }
        send(YAPPEncoder.cancel(reason: reason))
        finish(.failed(reason: reason), error: reason)
    }

    private func finish(_ final: TransferProtocolState, error: String) {
        guard !state.isTerminal else { return }
        timer?.invalidate()
        if senderPhase != .idle { senderPhase = .finished }
        if receiverPhase != .idle { receiverPhase = .finished }
        setState(final)
        delegate?.transferProtocol(self, didComplete: false, error: error)
    }

    private func handleTimeout() {
        switch (senderPhase, receiverPhase) {
        case (.awaitingCancelAck, _), (_, .awaitingCancelAck):
            // No CA. The cancel was sent; nothing more is owed.
            senderPhase = senderPhase == .idle ? .idle : .finished
            receiverPhase = receiverPhase == .idle ? .idle : .finished
            onCancelSettled?()
        default:
            guard !state.isTerminal else { return }
            let seconds = Int(responseTimeout)
            protocolError("No answer from the other station for \(seconds) seconds")
        }
    }

    private func armTimer(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
    }

    private func setState(_ newState: TransferProtocolState) {
        guard newState != state else { return }
        state = newState
        delegate?.transferProtocol(self, stateChanged: newState)
    }

    private func send(_ frame: Data) {
        delegate?.transferProtocol(self, needsToSend: frame)
    }
}
