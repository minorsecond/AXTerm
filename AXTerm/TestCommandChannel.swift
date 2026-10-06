//
//  TestCommandChannel.swift
//  AXTerm
//
//  A command folder for test mode, so a smoke test can drive transfers and
//  session text without the file picker or screen clicks.
//
//  Each instance watches its own folder, AXTerm-Test/commands-<instance> in
//  its temporary directory. A JSON file dropped there runs once, in name
//  order, through the same SessionCoordinator calls the buttons use, and a
//  <name>.result.json is written beside it: {"ok": true} or {"ok": false,
//  "error": "..."}. sendFile's result comes once its file has been read.
//  Only started with --test-mode.
//
//  {"action":"connect","to":"K0EPI-3"}
//  {"action":"disconnect","to":"K0EPI-3"}
//  {"action":"sendText","to":"K0EPI-3","text":"LIST"}          (sent with CR)
//  {"action":"sendFile","to":"K0EPI-3","file":"AXTerm Smoke Files/t1k_bin.bin",
//   "protocol":"axdp|yapp","compression":"global|off|lz4|deflate"}
//  {"action":"acceptOffer"|"declineOffer","file":"t1k_bin.bin"}
//  {"action":"cancelTransfer"|"pauseTransfer"|"resumeTransfer","file":"t1k_bin.bin"}
//  {"action":"cancelTransfer","file":"t1k_bin.bin","when":"endOfFileSent"}
//    (held until the YAPP sender's EF is out; the result comes then)
//
//  "file" for sendFile is relative to the files folder (Downloads in the
//  app); for the others it is the transfer's file name.
//

import Foundation

@MainActor
final class TestCommandChannel {

    struct Command: Decodable {
        let action: String
        var to: String?
        var file: String?
        var `protocol`: String?
        var compression: String?
        var text: String?
        /// For sendHex: bytes as hex, spaces allowed (`"05 01"`).
        var hex: String?
        /// For cancelTransfer: "endOfFileSent" holds the cancel until the
        /// YAPP sender's EF is out, so it lands between EF and AF.
        var when: String?
    }

    /// The channel test mode started at launch.
    static var running: TestCommandChannel?

    private let folder: URL
    private let filesFolder: URL
    private weak var coordinator: SessionCoordinator?
    private var timer: Timer?
    /// Work a command leaves to finish asynchronously; its result file is
    /// written when it returns. Set by `run`, taken by `poll`.
    private var pending: (() async -> String?)?

    init(folder: URL, coordinator: SessionCoordinator, filesFolder: URL) {
        self.folder = folder
        self.coordinator = coordinator
        self.filesFolder = filesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// The folder for this test instance, beside its test database.
    static func folder(instanceID: String) throws -> URL {
        let sanitized = instanceID.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return try DatabaseManager.ephemeralDatabaseFolder()
            .appendingPathComponent("commands-\(sanitized)", isDirectory: true)
    }

    func start(every interval: TimeInterval = 1) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Runs every command waiting in the folder, in name order. Returns the
    /// names run.
    @discardableResult
    func poll() -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".result.json") }
            .sorted()
        var ran: [String] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            let base = String(name.dropLast(".json".count))
            let error: String?
            pending = nil
            if let data = try? Data(contentsOf: url),
               let command = try? JSONDecoder().decode(Command.self, from: data) {
                error = run(command)
            } else {
                error = "Not a command: expected JSON with an \"action\""
            }
            try? FileManager.default.removeItem(at: url)
            if error == nil, let work = pending {
                pending = nil
                Task { @MainActor [weak self] in self?.writeResult(base, error: await work()) }
            } else {
                writeResult(base, error: error)
            }
            ran.append(base)
        }
        return ran
    }

    private func writeResult(_ base: String, error: String?) {
        var result: [String: Any] = ["ok": error == nil]
        if let error { result["error"] = error }
        if let out = try? JSONSerialization.data(withJSONObject: result) {
            try? out.write(to: folder.appendingPathComponent(base + ".result.json"))
        }
        TxLog.debug(.session, "Test command", ["name": base, "ok": error == nil, "error": error ?? ""])
    }

    /// Runs one command. Returns why it failed, or nil. A command that
    /// finishes later (sendFile reads its file off the main actor) leaves
    /// that work in `pending`.
    private func run(_ command: Command) -> String? {
        guard let coordinator else { return "No coordinator" }
        let manager = coordinator.sessionManager
        switch command.action {
        case "connect":
            guard let to = command.to else { return "connect needs \"to\"" }
            guard let frame = manager.connect(to: CallsignNormalizer.toAddress(to), path: DigiPath(),
                                              radio: coordinator.primaryRadioID) else {
                return "Could not connect to \(to)"
            }
            coordinator.sendFrame(frame)
            return nil

        case "disconnect":
            guard let to = command.to else { return "disconnect needs \"to\"" }
            // A connect still retrying is stopped too (smoke run issue 47).
            let peer = CallsignNormalizer.toAddress(to).display.uppercased()
            guard let session = manager.connectedSession(withPeer: CallsignNormalizer.toAddress(to))
                    ?? manager.sessions.values.first(where: {
                        $0.state == .connecting && $0.remoteAddress.display.uppercased() == peer
                    }) else {
                return "No session with \(to)"
            }
            if let frame = manager.disconnect(session: session) { coordinator.sendFrame(frame) }
            return nil

        case "sendHex":
            guard let to = command.to, let hex = command.hex else { return "sendHex needs \"to\" and \"hex\"" }
            let digits = hex.filter { !$0.isWhitespace }
            guard !digits.isEmpty, digits.count.isMultiple(of: 2),
                  digits.allSatisfy(\.isHexDigit) else { return "Not hex: \(hex)" }
            var bytes = Data()
            var index = digits.startIndex
            while index < digits.endIndex {
                let next = digits.index(index, offsetBy: 2)
                bytes.append(UInt8(digits[index..<next], radix: 16)!)
                index = next
            }
            let frames = manager.sendData(bytes, to: CallsignNormalizer.toAddress(to),
                                          radio: coordinator.primaryRadioID)
            for frame in frames { coordinator.sendFrame(frame) }
            return nil

        case "sendText":
            guard let to = command.to, let text = command.text else { return "sendText needs \"to\" and \"text\"" }
            let frames = manager.sendData(Data((text + "\r").utf8), to: CallsignNormalizer.toAddress(to),
                                          radio: coordinator.primaryRadioID)
            for frame in frames { coordinator.sendFrame(frame) }
            return nil

        case "sendFile":
            guard let to = command.to, let file = command.file else { return "sendFile needs \"to\" and \"file\"" }
            guard !file.split(separator: "/").contains("..") else { return "The file must be inside the files folder" }
            let url = filesFolder.appendingPathComponent(file)
            let transferProtocol: TransferProtocolType
            switch command.protocol ?? "axdp" {
            case "axdp": transferProtocol = .axdp
            case "yapp": transferProtocol = .yapp
            default: return "Unknown protocol \(command.protocol ?? "")"
            }
            let compression: TransferCompressionSettings
            switch command.compression ?? "global" {
            case "global": compression = .useGlobal
            case "off": compression = .disabled
            case "lz4": compression = .withAlgorithm(.lz4)
            case "deflate": compression = .withAlgorithm(.deflate)
            default: return "Unknown compression \(command.compression ?? "")"
            }
            // The read runs off the main actor and the result is written
            // when it is done (see `pending`).
            pending = { [coordinator] in
                await coordinator.startTransfer(to: to, fileURL: url, transferProtocol: transferProtocol,
                                                compressionSettings: compression)
            }
            return nil

        case "acceptOffer", "declineOffer":
            guard let file = command.file else { return "\(command.action) needs \"file\"" }
            guard let offer = coordinator.pendingIncomingTransfers.last(where: { $0.fileName == file }) else {
                return "No offer of \(file)"
            }
            if command.action == "acceptOffer" {
                coordinator.acceptIncomingTransfer(offer.id)
            } else {
                coordinator.declineIncomingTransfer(offer.id)
            }
            return nil

        case "cancelTransfer", "pauseTransfer", "resumeTransfer":
            guard let file = command.file else { return "\(command.action) needs \"file\"" }
            if let when = command.when {
                guard command.action == "cancelTransfer", when == "endOfFileSent" else {
                    return "Unknown \"when\" \(when) for \(command.action); only cancelTransfer takes endOfFileSent"
                }
            }
            guard let transfer = coordinator.transfers.last(where: { $0.fileName == file }) else {
                return "No transfer of \(file)"
            }
            if command.when != nil {
                let id = transfer.id
                pending = { [weak coordinator] in
                    await Self.cancelOnceEndOfFileIsOut(id, coordinator: coordinator)
                }
                return nil
            }
            switch command.action {
            case "cancelTransfer": coordinator.cancelTransfer(transfer.id)
            case "pauseTransfer": coordinator.pauseTransfer(transfer.id)
            default: coordinator.resumeTransfer(transfer.id)
            }
            return nil

        default:
            return "Unknown action \(command.action)"
        }
    }

    /// Cancels the moment the YAPP sender's EF goes out. EF to AF is one
    /// round trip, and the folder is read once a second, so a cancel aimed by
    /// hand mostly missed it (smoke run 2026-10-03-1, issue 60).
    private static func cancelOnceEndOfFileIsOut(_ id: UUID,
                                                 coordinator: SessionCoordinator?) async -> String? {
        await withCheckedContinuation { continuation in
            EndOfFileCancel(id: id, coordinator: coordinator) { continuation.resume(returning: $0) }.watch()
        }
    }
}

/// Watches one outbound YAPP transfer and cancels it as its EF goes out.
@MainActor
private final class EndOfFileCancel {
    private let id: UUID
    private weak var coordinator: SessionCoordinator?
    private let started = Date()
    private var finished: ((String?) -> Void)?

    init(id: UUID, coordinator: SessionCoordinator?, finished: @escaping (String?) -> Void) {
        self.id = id
        self.coordinator = coordinator
        self.finished = finished
    }

    private func finish(_ result: String?) {
        finished?(result)
        finished = nil
    }

    func watch() {
        guard finished != nil else { return }
        guard let coordinator,
              let transfer = coordinator.transfers.first(where: { $0.id == id }) else {
            return finish("The transfer is gone")
        }
        if let runner = coordinator.yappTransfers[id] {
            if runner.yapp.tooLateToCancel {
                coordinator.cancelTransfer(id)
                return finish(nil)
            }
            let id = self.id
            runner.yapp.onEndFileSent = { [weak self, weak coordinator] in
                coordinator?.cancelTransfer(id)
                self?.finish(nil)
            }
        }
        if !transfer.canCancel {
            return finish("The transfer ended before its EF went out (\(transfer.status))")
        }
        guard Date().timeIntervalSince(started) < 600 else { return finish("No EF in 10 minutes") }
        // Held by the timer until the transfer ends one way or the other.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            MainActor.assumeIsolated { self.watch() }
        }
    }
}
