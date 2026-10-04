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
//  "error": "..."}. Only started with --test-mode.
//
//  {"action":"connect","to":"K0EPI-3"}
//  {"action":"disconnect","to":"K0EPI-3"}
//  {"action":"sendText","to":"K0EPI-3","text":"LIST"}          (sent with CR)
//  {"action":"sendFile","to":"K0EPI-3","file":"AXTerm Smoke Files/t1k_bin.bin",
//   "protocol":"axdp|yapp","compression":"global|off|lz4|deflate"}
//  {"action":"acceptOffer"|"declineOffer","file":"t1k_bin.bin"}
//  {"action":"cancelTransfer"|"pauseTransfer"|"resumeTransfer","file":"t1k_bin.bin"}
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
    }

    /// The channel test mode started at launch.
    static var running: TestCommandChannel?

    private let folder: URL
    private let filesFolder: URL
    private weak var coordinator: SessionCoordinator?
    private var timer: Timer?

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
            if let data = try? Data(contentsOf: url),
               let command = try? JSONDecoder().decode(Command.self, from: data) {
                error = run(command)
            } else {
                error = "Not a command: expected JSON with an \"action\""
            }
            try? FileManager.default.removeItem(at: url)
            var result: [String: Any] = ["ok": error == nil]
            if let error { result["error"] = error }
            if let out = try? JSONSerialization.data(withJSONObject: result) {
                try? out.write(to: folder.appendingPathComponent(base + ".result.json"))
            }
            TxLog.debug(.session, "Test command", ["name": base, "ok": error == nil, "error": error ?? ""])
            ran.append(base)
        }
        return ran
    }

    /// Runs one command. Returns why it failed, or nil.
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
            guard let session = manager.connectedSession(withPeer: CallsignNormalizer.toAddress(to)),
                  let frame = manager.disconnect(session: session) else {
                return "No connected session with \(to)"
            }
            coordinator.sendFrame(frame)
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
            return coordinator.startTransfer(to: to, fileURL: url, transferProtocol: transferProtocol,
                                             compressionSettings: compression)

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
            guard let transfer = coordinator.transfers.last(where: { $0.fileName == file }) else {
                return "No transfer of \(file)"
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
}
