//
//  FullStackFuzzSupport.swift
//  AXTermTests
//
//  Two complete stations for fuzzing: a real PacketEngine and
//  SessionCoordinator each, joined by an in-memory KISS link that can lose,
//  duplicate, delay and chop up what it carries, and go silent. Everything
//  from KISS framing up is production code.
//
//  Real time, like TwoStationTransferTests: the AX.25 timers are short so a
//  run takes seconds.
//

import XCTest
@testable import AXTerm

/// A KISS link with seeded impairments. Frames stay in order, as on one
/// radio hop; a delay holds back everything behind it.
@MainActor
final class FuzzKISSLink: KISSLink {
    struct Impairment: CustomStringConvertible {
        var loss = 0.0
        var duplicate = 0.0
        var jitter: TimeInterval = 0
        /// Hand KISS bytes over in pieces, the way a serial port does.
        var chunked = false

        var description: String {
            String(format: "loss=%.2f dup=%.2f jitter=%.0fms%@", loss, duplicate, jitter * 1000,
                   chunked ? " chunked" : "")
        }
    }

    private(set) var state: KISSLinkState = .disconnected
    weak var delegate: KISSLinkDelegate?
    weak var peer: FuzzKISSLink?
    var impairment = Impairment()
    /// Radio silence: frames sent while either end is silenced never arrive.
    var silenced = false
    private(set) var framesSent = 0
    /// SABMs sent, to spot a link set up again in the middle of something.
    private(set) var sabmsSent = 0
    private(set) var framesDropped = 0
    private var rng: PropertyRNG
    private var lastDeliveryAt = DispatchTime.now()
    /// The last frames sent, oldest first, for a problem report: what the
    /// link was doing when something went wrong.
    private(set) var trace: [(at: Date, line: String)] = []
    var traceLimit = 400
    var label = "?"

    var endpointDescription: String { "fuzz" }

    init(seed: UInt64) { rng = PropertyRNG(seed: seed) }

    func open() {
        state = .connected
        delegate?.linkDidChangeState(.connected)
    }

    func close() {
        state = .disconnected
        delegate?.linkDidChangeState(.disconnected)
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        framesSent += 1
        completion(nil)
        guard !silenced, !(peer?.silenced ?? true) else { framesDropped += 1; record(data, "silenced"); return }
        if chance(impairment.loss) { framesDropped += 1; record(data, "LOST"); return }
        deliver(data)
        let twice = chance(impairment.duplicate)
        if twice { deliver(data) }
        record(data, twice ? "dup" : "")
    }

    private func record(_ kiss: Data, _ note: String) {
        let frame = FuzzKISSLink.describe(kiss)
        if frame.hasPrefix("SABM") { sabmsSent += 1 }
        trace.append((Date(), "\(label)> \(frame) \(note)"))
        if trace.count > traceLimit { trace.removeFirst(trace.count - traceLimit) }
    }

    /// "I s3 r5 P 128B", "RR r4 F", "SABM P" and so on.
    static func describe(_ kiss: Data) -> String {
        var parser = KISSFrameParser()
        guard case .ax25(let ax25)? = parser.feed(kiss).first,
              let frame = AX25.decodeFrame(ax25: ax25) else { return "? \(kiss.count)B" }
        let c = AX25ControlFieldDecoder.decode(control: frame.control, controlByte1: frame.controlByte1)
        let pf = c.pf == 1 ? " P/F" : ""
        switch c.frameClass {
        case .I: return "I s\(c.ns ?? -1) r\(c.nr ?? -1)\(pf) \(frame.info.count)B"
        case .S: return "\(c.sType.map { "\($0)" } ?? "S") r\(c.nr ?? -1)\(pf)"
        case .U: return "\(c.uType.map { "\($0)" } ?? "U")\(pf) \(frame.info.count)B"
        default: return "\(c.frameClass)"
        }
    }

    private func chance(_ p: Double) -> Bool {
        p > 0 && Double.random(in: 0..<1, using: &rng) < p
    }

    private func deliver(_ data: Data) {
        let delay = impairment.jitter > 0 ? Double.random(in: 0...impairment.jitter, using: &rng) : 0
        let at = max(lastDeliveryAt, DispatchTime.now() + delay)
        lastDeliveryAt = at
        var pieces = [data]
        if impairment.chunked, data.count > 2 {
            pieces = []
            var rest = data[...]
            while !rest.isEmpty {
                let n = min(rest.count, Int.random(in: 1...max(1, data.count / 2), using: &rng))
                pieces.append(Data(rest.prefix(n)))
                rest = rest.dropFirst(n)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: at) { [weak peer] in
            guard let peer, !peer.silenced else { return }
            for piece in pieces { peer.delegate?.linkDidReceive(piece) }
        }
    }
}

/// One fuzzable station: settings, engine, coordinator, link and a folder.
@MainActor
final class FuzzStation {
    let callsign: String
    let address: AX25Address
    let settings: AppSettingsStore
    let engine: PacketEngine
    let coordinator: SessionCoordinator
    let link: FuzzKISSLink
    let folder: URL
    let notifications = RecordingTransferNotifications()
    /// Text the terminal would have shown.
    private(set) var terminalText = Data()

    init(callsign: String, seed: UInt64) {
        self.callsign = callsign
        address = CallsignNormalizer.toAddress(callsign)
        let defaults = TestDefaults.make("Fuzz-\(callsign)")
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        settings = AppSettingsStore(defaults: defaults)
        settings.adoptStationCallsign(callsign)
        settings.updateRadio(settings.radios[0].id) {
            $0.enabled = true
            $0.host = "127.0.0.1"
            $0.port = 9
        }
        let link = FuzzKISSLink(seed: seed)
        link.label = String(callsign.prefix(4).suffix(1))
        self.link = link
        engine = PacketEngine(settings: settings, notificationScheduler: notifications,
                              linkFactory: { _ in link })
        coordinator = SessionCoordinator()
        coordinator.localCallsign = callsign
        coordinator.appSettings = settings
        coordinator.subscribeToPackets(from: engine)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fuzz-\(callsign)-\(UUID().uuidString)", isDirectory: true)
        coordinator.receivedFilesFolderOverride = folder

        // Short timers so a run takes seconds; more retries than the
        // two-station tests so an impaired link is not given up on at once.
        let fast = AX25SessionConfig(windowSize: 4, paclen: 128, maxRetries: 10,
                                     rtoMin: 0.3, rtoMax: 1.2, initialRto: 0.5,
                                     t2AckDelay: 0.1, adaptiveTimeout: false)
        coordinator.sessionManager.getConfigForDestination = { _, _, _ in fast }
        coordinator.sessionManager.defaultConfig = fast
        coordinator.adaptiveTransmissionEnabled = false
        coordinator.transferWatchdogInterval = 0.2
        coordinator.yappResponseTimeout = 6
        coordinator.transferTimeouts.awaitingAcceptance = 20
        coordinator.transferTimeouts.outboundStall = 10
        coordinator.transferTimeouts.awaitingCompletion = 10
        coordinator.transferTimeouts.inboundStall = 10

        coordinator.sessionManager.onDataReceived = { [weak self] _, data in
            self?.terminalText.append(data)
        }
    }

    func connectLink(to other: FuzzStation) {
        link.peer = other.link
        engine.connectUsingSettings()
    }

    var session: AX25Session? { coordinator.connectedSessions.first }

    func transfer(named name: String) -> BulkTransfer? {
        coordinator.transfers.last { $0.fileName == name }
    }

    func savedData(_ transfer: BulkTransfer?) -> Data? {
        transfer?.savedFilePath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    }

    func tearDown() {
        coordinator.transferWatchdogTask?.cancel()
        for session in coordinator.sessionManager.sessions.values {
            coordinator.sessionManager.forceDisconnect(session: session)
        }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Picks a run's parameters from its seed.
struct FuzzPicker {
    private var rng: PropertyRNG
    init(seed: UInt64) { rng = PropertyRNG(seed: seed ^ 0xF0F0_1234_ABCD_0001) }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo...hi, using: &rng) }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func pick<T>(_ options: [T]) -> T { options[Int.random(in: 0..<options.count, using: &rng)] }
    mutating func element<T>(_ options: [T]) -> T? { options.isEmpty ? nil : pick(options) }
    mutating func bytes(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }) }
}

/// Seeds for a full-stack fuzz test: a few in the normal run,
/// AXTERM_FULLSTACK_FUZZ_SEEDS=<n> (TEST_RUNNER_ prefix through xcodebuild)
/// for a soak, AXTERM_FULLSTACK_FUZZ_SEED=<n>[,<n>...] to replay some.
enum FullStackFuzz {
    /// AXTERM_FULLSTACK_FUZZ_TRACE=1 adds the frames around each problem
    /// to the report.
    static var tracing: Bool {
        ProcessInfo.processInfo.environment["AXTERM_FULLSTACK_FUZZ_TRACE"] == "1"
    }

    static func seeds(normal: Int) -> [UInt64] {
        let env = ProcessInfo.processInfo.environment
        if let list = env["AXTERM_FULLSTACK_FUZZ_SEED"] {
            let seeds = list.split(separator: ",").compactMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
            if !seeds.isEmpty { return seeds }
        }
        let count = env["AXTERM_FULLSTACK_FUZZ_SEEDS"].flatMap(Int.init) ?? normal
        return (1...max(1, count)).map(UInt64.init)
    }

    /// Both stations' frames since `since`, merged in time order, the last
    /// `limit` of them, for a problem report.
    @MainActor
    static func trace(_ a: FuzzStation, _ b: FuzzStation, since: Date, limit: Int = 120) -> [String] {
        let merged = (a.link.trace + b.link.trace).filter { $0.at >= since }.sorted { $0.at < $1.at }
        return merged.suffix(limit).map {
            String(format: "      %7.2f ", $0.at.timeIntervalSince(since)) + $0.line
        }
    }

    /// Waits on the main actor until `condition` holds or `timeout` passes.
    @MainActor
    static func wait(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}
