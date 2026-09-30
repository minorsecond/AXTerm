import XCTest
@testable import AXTerm

/// A station calling the mailbox, played against the real session layer.
///
/// Everything below the caller is production code: the SABM goes into the
/// coordinator's own `AX25SessionManager`, the mailbox answers it through its
/// inbound subscriber and delivery claim, and what the mailbox transmits comes
/// back here as the `OutboundFrame`s the radio would have sent. The caller
/// acknowledges I-frames the way a real peer does (piggybacked N(R) and RR),
/// fragments what it sends at 128 bytes the way a TNC does, and ignores
/// retransmissions by N(S), so a YAPP block split across two frames arrives
/// split across two frames.
@MainActor
final class BBSSimulatedCaller {

    let manager: AX25SessionManager
    let address: AX25Address
    let mailbox: AX25Address

    /// Frames the station transmitted and this caller has not read yet.
    var outbox: [OutboundFrame] = []
    /// Every byte the mailbox delivered, in order.
    private(set) var received = Data()
    /// What the caller's software does with delivered bytes.
    var onBytes: ((Data) -> Void)?
    /// Bytes the caller's software wants sent; flushed as the pump runs.
    var pendingSends: [Data] = []

    private var vs = 0
    private var vr = 0

    init(manager: AX25SessionManager, address: AX25Address, mailbox: AX25Address) {
        self.manager = manager
        self.address = address
        self.mailbox = mailbox
    }

    /// Received bytes as text, control bytes and all.
    var text: String { String(decoding: received, as: UTF8.self) }

    func connect() {
        vs = 0
        vr = 0
        if let ua = manager.handleInboundSABM(from: address, to: mailbox,
                                              path: DigiPath(), radio: .primary) {
            outbox.append(ua)
        }
    }

    func disconnect() {
        if let reply = manager.handleInboundDISC(from: address, path: DigiPath(), radio: .primary) {
            outbox.append(reply)
        }
    }

    func send(_ bytes: Data) {
        // Rebased: a slice keeps its parent's indices.
        let data = Data(bytes)
        var offset = 0
        repeat {
            let end = min(offset + 128, data.count)
            let chunk = data.subdata(in: offset..<end)
            if let reply = manager.handleInboundIFrame(
                from: address, path: DigiPath(), radio: .primary,
                ns: vs, nr: vr, pf: false, payload: chunk) {
                outbox.append(reply)
            }
            vs = (vs + 1) % 8
            offset = end
        } while offset < data.count
    }

    func type(_ line: String) { send(Data((line + "\r").utf8)) }

    /// Reads what the station sent, acknowledging as it goes, until nothing
    /// is left. Returns whether any new data arrived.
    @discardableResult
    func drain() -> Bool {
        var progressed = false
        while !outbox.isEmpty || !pendingSends.isEmpty {
            while !pendingSends.isEmpty {
                send(pendingSends.removeFirst())
            }
            let frames = outbox
            outbox.removeAll()
            var fresh = false
            for frame in frames where frame.frameType == "i" {
                // A retransmission, or one ahead of a gap: a real peer would
                // not deliver it either.
                guard frame.ns == vr else { continue }
                vr = (vr + 1) % 8
                fresh = true
                progressed = true
                received.append(frame.payload)
                onBytes?(frame.payload)
            }
            if fresh {
                outbox.append(contentsOf: manager.handleInboundRRFrames(
                    from: address, path: DigiPath(), radio: .primary, nr: vr))
            }
        }
        return progressed
    }

    /// Runs the exchange until `condition` holds or `timeout` passes.
    @discardableResult
    func pump(timeout: TimeInterval = 10,
              until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            drain()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        drain()
        return condition()
    }

    func clearReceived() { received = Data() }
}

/// A caller's YAPP software, receive side: `YAPPProtocol` itself, with the
/// same frame reassembly the mailbox uses in front of it.
nonisolated final class CallerYAPPReceiver: FileTransferProtocolDelegate, @unchecked Sendable {
    let driver = YAPPProtocol()
    var framing = YAPPFrameAssembler()
    var toSend: [Data] = []
    var text = Data()
    var file: Data?
    var metadata: TransferFileMetadata?
    var completed: Bool?
    var error: String?
    /// What to do with the header: accept, or refuse with CAN.
    var accepts = true

    init() { driver.delegate = self }

    func consume(_ bytes: Data) {
        for piece in framing.push(bytes) {
            switch piece {
            case .frame(let frame): driver.handleIncomingData(frame)
            case .text(let typed): text.append(typed)
            case .malformed: error = "malformed"
            }
        }
    }

    var textString: String { String(decoding: text, as: UTF8.self) }

    func transferProtocol(_ transfer: FileTransferProtocol, needsToSend data: Data) {
        toSend.append(data)
    }
    func transferProtocol(_ transfer: FileTransferProtocol,
                          didUpdateProgress progress: Double, bytesSent: Int) {}
    func transferProtocol(_ transfer: FileTransferProtocol,
                          didComplete successfully: Bool, error: String?) {
        completed = successfully
        self.error = error
    }
    func transferProtocol(_ transfer: FileTransferProtocol,
                          didReceiveFile data: Data, metadata: TransferFileMetadata) {
        file = data
        self.metadata = metadata
    }
    func transferProtocol(_ transfer: FileTransferProtocol,
                          requestsConfirmation metadata: TransferFileMetadata) {
        if accepts { driver.acceptTransfer() } else { driver.rejectTransfer(reason: "no") }
    }
    func transferProtocol(_ transfer: FileTransferProtocol,
                          stateChanged newState: TransferProtocolState) {}
}

/// A caller's YAPP software, send side, for uploads.
nonisolated final class CallerYAPPSender: FileTransferProtocolDelegate, @unchecked Sendable {
    let driver = YAPPProtocol()
    var framing = YAPPFrameAssembler()
    var toSend: [Data] = []
    var text = Data()
    var completed: Bool?
    var error: String?

    init() { driver.delegate = self }

    /// Mailbox replies go to the sender's ACK and NAK handlers, as the
    /// mailbox's own download path does in the other direction.
    func consume(_ bytes: Data) {
        for piece in framing.push(bytes) {
            switch piece {
            case .frame(let frame):
                switch frame.first.flatMap(YAPPControlChar.init(rawValue:)) {
                case .ack, .soh: driver.handleAck(data: frame)
                case .nak, .can: driver.handleNak(data: frame)
                default: break
                }
            case .text(let typed): text.append(typed)
            case .malformed: error = "malformed"
            }
        }
    }

    var textString: String { String(decoding: text, as: UTF8.self) }

    func transferProtocol(_ transfer: FileTransferProtocol, needsToSend data: Data) {
        toSend.append(data)
    }
    func transferProtocol(_ transfer: FileTransferProtocol,
                          didUpdateProgress progress: Double, bytesSent: Int) {}
    func transferProtocol(_ transfer: FileTransferProtocol,
                          didComplete successfully: Bool, error: String?) {
        completed = successfully
        self.error = error
    }
    func transferProtocol(_ transfer: FileTransferProtocol,
                          didReceiveFile data: Data, metadata: TransferFileMetadata) {}
    func transferProtocol(_ transfer: FileTransferProtocol,
                          requestsConfirmation metadata: TransferFileMetadata) {}
    func transferProtocol(_ transfer: FileTransferProtocol,
                          stateChanged newState: TransferProtocolState) {}
}
