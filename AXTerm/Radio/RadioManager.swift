import Combine
import Foundation

/// One AX.25 frame as it came off a link, with the radio it belongs to.
nonisolated struct RadioIngest: Sendable {
    let radio: RadioID
    let ax25: Data
    let kissPort: UInt8
    let linkKey: String
    let linkDescription: String
    let tcpEndpoint: KISSEndpoint?
    let at: Date
}

/// What the manager reports upward besides frames.
@MainActor
protocol RadioManagerDelegate: AnyObject {
    func radioManager(_ manager: RadioManager, link: LinkSession, didReceiveBytes data: Data)
    func radioManager(_ manager: RadioManager, link: LinkSession, didReceiveTelemetry frame: Data, port: UInt8)
    func radioManager(_ manager: RadioManager, link: LinkSession, didReceiveUnknown command: UInt8, payload: Data)
    func radioManager(_ manager: RadioManager, link: LinkSession, didChangeState state: KISSLinkState, from previous: KISSLinkState)
    func radioManager(_ manager: RadioManager, link: LinkSession, didError message: String)
    /// A frame arrived on a port no radio claims. Reported once per link and
    /// port, so a misconfigured Direwolf channel says so without flooding.
    func radioManager(_ manager: RadioManager, link: LinkSession, droppedFrameOnUnassignedPort port: UInt8)
    /// The built-in modem's levels, carrier and PTT, a few times a second.
    func radioManager(_ manager: RadioManager, link: LinkSession, didUpdateModemTelemetry telemetry: ModemTelemetry)
    /// The radio's frequency and mode, as CI-V reports them.
    func radioManager(_ manager: RadioManager, link: LinkSession, didUpdateRigStatus status: RigStatus, model: String?)
}

/// The modem-only notifications are optional: a delegate that never sees a
/// sound modem need not know one exists.
extension RadioManagerDelegate {
    func radioManager(_ manager: RadioManager, link: LinkSession, didUpdateModemTelemetry telemetry: ModemTelemetry) {}
    func radioManager(_ manager: RadioManager, link: LinkSession, didUpdateRigStatus status: RigStatus, model: String?) {}
}

/// The station's radios and the links that carry them.
///
/// Owns one `LinkSession` per byte stream and a table saying which radio
/// each port of each stream belongs to. `reconcile` brings the open links into
/// line with the enabled profiles: a link that is still wanted is kept (a
/// serial or Bluetooth one has its config updated in place, which its own
/// transport turns into a reconnect only when the device or baud changed), a
/// link no longer wanted is closed, a new one is opened. Two radios on one
/// Direwolf share a link and differ by port.
///
/// Frames come out of `ingest` already attributed to a radio. Frames go in
/// with a radio, and leave on that radio's link with that radio's port.
@MainActor
final class RadioManager: ObservableObject, LinkSessionDelegate {

    typealias LinkFactory = (RadioProfile) -> KISSLink?

    /// Every AX.25 frame heard, with its radio.
    let ingest = PassthroughSubject<RadioIngest, Never>()

    /// The link state of every radio, for the status surfaces. A radio whose
    /// link has not been opened is `.disconnected`.
    @Published private(set) var radioStates: [RadioID: KISSLinkState] = [:]

    /// The radios as last reconciled: enabled and not archived, in order.
    @Published private(set) var profiles: [RadioProfile] = []

    /// Why a radio has no link, for the ones the factory refused: a sound
    /// modem on iOS, a modem with no audio device chosen.
    @Published private(set) var unavailableReasons: [RadioID: String] = [:]
    /// The built-in modem's telemetry, per radio.
    @Published private(set) var modemTelemetry: [RadioID: ModemTelemetry] = [:]
    /// What the radio reports about itself over CI-V, per radio.
    @Published private(set) var rigStatus: [RadioID: RigStatus] = [:]

    private(set) var sessions: [String: LinkSession] = [:]
    /// linkKey → port → radio.
    private var demux: [String: [UInt8: RadioID]] = [:]
    private var assignment: [RadioID: (key: String, port: UInt8)] = [:]
    private var reportedUnassigned: Set<String> = []
    /// Frames that arrived on a port no radio claims.
    private(set) var unassignedDrops = 0

    weak var delegate: RadioManagerDelegate?
    private let linkFactory: LinkFactory

    /// Explicit nonisolated deinit: an implicitly isolated deallocating
    /// deinit aborts when the last reference is dropped off the main
    /// executor (see AdaptiveStatusStore and [[axterm-mainactor-default-isolation]]).
    nonisolated deinit {}

    init(linkFactory: @escaping LinkFactory = RadioManager.defaultLinkFactory) {
        self.linkFactory = linkFactory
    }

    // MARK: - Reading

    /// The first enabled radio: the one the single-radio surfaces describe.
    var primaryRadioID: RadioID? { profiles.first?.id }

    var primarySession: LinkSession? {
        primaryRadioID.flatMap { session(for: $0) }
    }

    func session(for radio: RadioID) -> LinkSession? {
        assignment[radio].flatMap { sessions[$0.key] }
    }

    func kissPort(for radio: RadioID) -> UInt8 {
        assignment[radio]?.port ?? 0
    }

    func state(of radio: RadioID) -> KISSLinkState {
        radioStates[radio] ?? .disconnected
    }

    /// The radios sharing one byte stream, in port order.
    func radios(onLink key: String) -> [RadioID] {
        (demux[key] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
    }

    func profile(_ radio: RadioID) -> RadioProfile? {
        profiles.first { $0.id == radio }
    }

    /// One status for all radios, for the surfaces that still show one dot.
    var aggregateStatus: ConnectionStatus {
        RadioPresentation.aggregateStatus(profiles.map { ConnectionStatus(linkState: state(of: $0.id)) })
    }

    // MARK: - Reconciling

    /// Brings the links into line with `radios`. Returns how many links were
    /// newly created, so the caller can tell a fresh connection from a
    /// settings tweak that changed nothing about the wire.
    @discardableResult
    func reconcile(_ radios: [RadioProfile], open shouldOpen: Bool) -> Int {
        let desired = radios.filter { $0.enabled && !$0.archived }
        profiles = desired
        var unavailable: [RadioID: String] = [:]

        var newDemux: [String: [UInt8: RadioID]] = [:]
        var newAssignment: [RadioID: (key: String, port: UInt8)] = [:]
        for radio in desired {
            let key = radio.linkKey
            if newDemux[key]?[radio.kissPort] != nil {
                // Two radios on one link and port: the first keeps it. The
                // settings list flags this as an issue; here it must simply
                // not become two owners of one byte stream.
                continue
            }
            newDemux[key, default: [:]][radio.kissPort] = radio.id
            newAssignment[radio.id] = (key, radio.kissPort)
        }

        // Links nobody wants any more.
        for (key, session) in sessions where newDemux[key] == nil {
            session.close()
            sessions.removeValue(forKey: key)
        }

        // Links to keep, brought up to date; links to create.
        var created = 0
        for key in newDemux.keys.sorted() {
            guard let representative = desired.first(where: { $0.linkKey == key }) else { continue }
            if let existing = sessions[key] {
                update(existing, from: representative)
                if shouldOpen, existing.state == .disconnected || existing.state == .failed {
                    existing.open()
                }
                continue
            }
            guard let link = linkFactory(representative) else {
                for radio in desired where radio.linkKey == key {
                    unavailable[radio.id] = Self.unsupportedReason(for: radio) ?? "This radio's link could not be created."
                }
                continue
            }
            let session = LinkSession(
                key: key, link: link, transport: representative.kind,
                tcpEndpoint: representative.kind == .tcp
                    ? KISSEndpoint(host: representative.host, port: UInt16(clamping: representative.port))
                    : nil)
            session.delegate = self
            sessions[key] = session
            created += 1
            if shouldOpen { session.open() }
        }

        demux = newDemux
        assignment = newAssignment
        reportedUnassigned = reportedUnassigned.filter { newDemux[$0.components(separatedBy: "#").first ?? ""] != nil }
        unavailableReasons = unavailable
        let live = Set(desired.map(\.id))
        modemTelemetry = modemTelemetry.filter { live.contains($0.key) }
        rigStatus = rigStatus.filter { live.contains($0.key) }
        refreshRadioStates()
        return created
    }

    /// Why a radio can have no link here, in the operator's words; nil when
    /// the factory should manage.
    nonisolated static func unsupportedReason(for radio: RadioProfile) -> String? {
        guard radio.kind == .modem else { return nil }
        #if os(macOS)
        if radio.audioInputDeviceUID.isEmpty || radio.audioOutputDeviceUID.isEmpty {
            return "Choose an audio input and output device for this radio."
        }
        return nil
        #else
        return "The sound modem needs a Mac. Use this radio from AXTerm on your Mac, or reach a TNC over the network or Bluetooth here."
        #endif
    }

    /// Applies what can change without reopening a link. The transports
    /// decide for themselves whether a change needs a reconnect.
    private func update(_ session: LinkSession, from radio: RadioProfile) {
        #if os(macOS)
        if let serial = session.link as? KISSLinkSerial {
            serial.updateConfig(SerialConfig(
                devicePath: serial.config.devicePath,
                baudRate: radio.serialBaudRate,
                autoReconnect: radio.serialAutoReconnect,
                mobilinkdConfig: radio.mobilinkdConfig))
        }
        #endif
        if let ble = session.link as? KISSLinkBLE {
            ble.updateConfig(BLEConfig(
                peripheralUUID: radio.blePeripheralUUID,
                peripheralName: radio.blePeripheralName,
                autoReconnect: radio.bleAutoReconnect,
                mobilinkdConfig: radio.mobilinkdConfig))
        }
        #if os(macOS)
        if let modem = session.link as? ModemRadioLink, let config = radio.modemConfig {
            modem.updateConfig(config)
        }
        #endif
    }

    func openAll() {
        for session in sessions.values where session.state == .disconnected || session.state == .failed {
            session.open()
        }
        refreshRadioStates()
    }

    func closeAll() {
        for session in sessions.values { session.close() }
        refreshRadioStates()
    }

    func open(_ radio: RadioID) {
        session(for: radio)?.open()
        refreshRadioStates()
    }

    /// Closes the radio's link. A link shared by two radios closes for both:
    /// there is one socket.
    func close(_ radio: RadioID) {
        session(for: radio)?.close()
        refreshRadioStates()
    }

    // MARK: - Sending

    /// An AX.25 frame out of one radio, KISS-framed with that radio's port.
    /// False when the radio has no connected link.
    @discardableResult
    func send(ax25: Data, radio: RadioID, completion: @escaping (Error?) -> Void = { _ in }) -> Bool {
        guard let session = session(for: radio), session.state == .connected else { return false }
        session.sendAX25(ax25, port: kissPort(for: radio), completion: completion)
        return true
    }

    /// Already-framed KISS bytes — hardware commands — out of one radio's link.
    @discardableResult
    func sendRaw(_ kissFramed: Data, radio: RadioID, completion: @escaping (Error?) -> Void = { _ in }) -> Bool {
        guard let session = session(for: radio) else { return false }
        session.send(kissFramed, completion: completion)
        return true
    }

    // MARK: - LinkSessionDelegate

    func linkSession(_ session: LinkSession, didReceiveBytes data: Data) {
        delegate?.radioManager(self, link: session, didReceiveBytes: data)
    }

    func linkSession(_ session: LinkSession, didReceiveAX25 frame: Data, port: UInt8) {
        guard let radio = demux[session.key]?[port] else {
            unassignedDrops += 1
            let mark = "\(session.key)#\(port)"
            if !reportedUnassigned.contains(mark) {
                reportedUnassigned.insert(mark)
                delegate?.radioManager(self, link: session, droppedFrameOnUnassignedPort: port)
            }
            return
        }
        ingest.send(RadioIngest(radio: radio, ax25: frame, kissPort: port, linkKey: session.key,
                                linkDescription: session.endpointDescription,
                                tcpEndpoint: session.tcpEndpoint, at: Date()))
    }

    func linkSession(_ session: LinkSession, didReceiveTelemetry frame: Data, port: UInt8) {
        delegate?.radioManager(self, link: session, didReceiveTelemetry: frame, port: port)
    }

    func linkSession(_ session: LinkSession, didReceiveUnknown command: UInt8, payload: Data) {
        delegate?.radioManager(self, link: session, didReceiveUnknown: command, payload: payload)
    }

    func linkSession(_ session: LinkSession, didChangeState state: KISSLinkState, from previous: KISSLinkState) {
        refreshRadioStates()
        delegate?.radioManager(self, link: session, didChangeState: state, from: previous)
    }

    func linkSession(_ session: LinkSession, didError message: String) {
        delegate?.radioManager(self, link: session, didError: message)
    }

    func linkSession(_ session: LinkSession, didUpdateModemTelemetry telemetry: ModemTelemetry) {
        for radio in radios(onLink: session.key) { modemTelemetry[radio] = telemetry }
        delegate?.radioManager(self, link: session, didUpdateModemTelemetry: telemetry)
    }

    func linkSession(_ session: LinkSession, didUpdateRigStatus status: RigStatus, model: String?) {
        for radio in radios(onLink: session.key) { rigStatus[radio] = status }
        delegate?.radioManager(self, link: session, didUpdateRigStatus: status, model: model)
    }

    private func refreshRadioStates() {
        var states: [RadioID: KISSLinkState] = [:]
        for radio in profiles {
            states[radio.id] = session(for: radio.id)?.state ?? .disconnected
        }
        if states != radioStates { radioStates = states }
    }

    // MARK: - Links from profiles

    /// The transport a profile asks for. Serial exists only where there is a
    /// serial port — iOS has no IOKit and no user-accessible USB serial — so
    /// there a serial profile reaches its TNC over the network instead, as
    /// the engine always did.
    nonisolated static func defaultLinkFactory(_ radio: RadioProfile) -> KISSLink? {
        switch radio.kind {
        case .tcp:
            guard radio.port > 0, radio.port <= 65_535 else { return nil }
            return KISSLinkNetwork(host: radio.host, port: UInt16(radio.port))
        case .serial:
            #if os(macOS)
            return KISSLinkSerial(config: SerialConfig(
                devicePath: SerialDevicePathResolver.resolve(radio.serialDevicePath),
                baudRate: radio.serialBaudRate,
                autoReconnect: radio.serialAutoReconnect,
                mobilinkdConfig: radio.mobilinkdConfig))
            #else
            guard radio.port > 0, radio.port <= 65_535 else { return nil }
            return KISSLinkNetwork(host: radio.host, port: UInt16(radio.port))
            #endif
        case .ble:
            return KISSLinkBLE(config: BLEConfig(
                peripheralUUID: radio.blePeripheralUUID,
                peripheralName: radio.blePeripheralName,
                autoReconnect: radio.bleAutoReconnect,
                mobilinkdConfig: radio.mobilinkdConfig))
        case .modem:
            #if os(macOS)
            guard let config = radio.modemConfig,
                  !config.audioInputDeviceUID.isEmpty, !config.audioOutputDeviceUID.isEmpty else { return nil }
            return ModemRadioLink(
                config: config,
                audio: CoreAudioModemIO(inputUID: config.audioInputDeviceUID, outputUID: config.audioOutputDeviceUID,
                                        inputChannel: config.inputChannel))
            #else
            return nil
            #endif
        }
    }
}

/// Finds a serial TNC when the configured path has gone stale.
nonisolated enum SerialDevicePathResolver {
    /// The configured path if it exists, else the first `/dev/cu.*usbmodem*`
    /// (a TNC4 is CDC-ACM), else the configured path unchanged so the link
    /// reports the missing device itself. Never writes settings.
    static func resolve(_ configuredPath: String) -> String {
        if !configuredPath.isEmpty && FileManager.default.fileExists(atPath: configuredPath) {
            return configuredPath
        }
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: "/dev") {
            let usb = contents
                .filter { $0.hasPrefix("cu.") && $0.lowercased().contains("usbmodem") }
                .sorted()
            if let first = usb.first { return "/dev/\(first)" }
        }
        return configuredPath
    }
}
