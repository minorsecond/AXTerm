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
    /// A link the operator wants open has been down long enough to say so.
    /// Once per outage, and never for a machine that was asleep.
    func radioManager(_ manager: RadioManager, link: LinkSession, hasBeenDownFor seconds: TimeInterval)
    /// The built-in modem's levels, carrier and PTT, a few times a second.
    func radioManager(_ manager: RadioManager, link: LinkSession, didUpdateModemTelemetry telemetry: ModemTelemetry)
    /// The radio's frequency and mode, as CI-V reports them.
    func radioManager(_ manager: RadioManager, link: LinkSession, didUpdateRigStatus status: RigStatus, model: String?)
}

/// The modem-only notifications are optional: a delegate that never sees a
/// sound modem need not know one exists.
extension RadioManagerDelegate {
    func radioManager(_ manager: RadioManager, link: LinkSession, hasBeenDownFor seconds: TimeInterval) {}
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
    /// The radio's receive settings over CI-V, per radio: the latest audit
    /// and what changed during the session. Only for a connected radio
    /// with CI-V; a radio without it has no entry.
    @Published private(set) var rigReceive: [RadioID: RigReceiveAudit.Report] = [:]

    private(set) var sessions: [String: LinkSession] = [:]
    /// linkKey → port → radio.
    private var demux: [String: [UInt8: RadioID]] = [:]
    private var assignment: [RadioID: (key: String, port: UInt8)] = [:]
    private var reportedUnassigned: Set<String> = []
    /// Frames that arrived on a port no radio claims.
    private(set) var unassignedDrops = 0
    /// How long each wanted link has been down, and which outages have been
    /// reported. See `LinkOutageWatch` for why this exists at all.
    private var outages = LinkOutageWatch()
    private var outageTimer: Timer?
    /// The KISS timing last sent to each radio whose link does not send it
    /// by itself (`RadioProfile.managerSendsTiming`), so a settings write
    /// that leaves the timing alone sends nothing.
    private var sentTiming: [RadioID: KISSTimingParameters] = [:]

    /// The operator pressed Disconnect, and has not connected since.
    ///
    /// While this is set nothing opens a link by itself: not a settings
    /// write, not the radio's page closing, not a wake from sleep. Their next
    /// Connect (`reconcile(_:open: true)`, `openAll`) clears it. Before this,
    /// any later write to a radio's settings reconciled with `open: true` and
    /// reopened every link, so a TNC4's port was back in use moments after
    /// Disconnect (2026-09-30).
    private(set) var isHeldClosed = false

    /// A link was retired while the settings page held off reconciling
    /// (see `retireLinksOfMovedRadios`), so the links no longer match the
    /// settings even when the settings ended where they started. Cleared by
    /// the next reconcile.
    private(set) var hasRetiredLinks = false

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

    /// Which radios a link carries.
    ///
    /// Usually one. Several when a shared TNC demultiplexes them by KISS port
    /// onto a single byte stream, in which case that link coming up or going
    /// down is news for all of them — so the console attributes the notice to
    /// every radio on it rather than picking one. Empty when the link is not
    /// assigned to anything, which is a link on its way in or out.
    func radios(carriedBy link: LinkSession) -> Set<RadioID> {
        let keys = sessions.compactMap { $0.value === link ? $0.key : nil }
        guard !keys.isEmpty else { return [] }
        return Set(assignment.compactMap { keys.contains($0.value.key) ? $0.key : nil })
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
    ///
    /// `open: true` is an operator's Connect, and lifts a Disconnect's hold.
    @discardableResult
    func reconcile(_ radios: [RadioProfile], open shouldOpen: Bool) -> Int {
        if shouldOpen { isHeldClosed = false }
        hasRetiredLinks = false
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
                    unavailable[radio.id] = Self.unsupportedReason(for: radio) ?? Self.linkCouldNotBeCreated
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
        rigReceive = rigReceive.filter { live.contains($0.key) }
        refreshRadioStates()
        for radio in desired { sendTimingIfNeeded(radio) }
        return created
    }

    /// The reconcile a settings write asks for, as opposed to an operator's
    /// Connect: links are brought into line with the settings (a link no
    /// longer configured is closed, a new one is made), and opened only when
    /// the operator has not pressed Disconnect.
    @discardableResult
    func reconcileAfterSettingsChange(_ radios: [RadioProfile]) -> Int {
        reconcile(radios, open: !isHeldClosed)
    }

    /// Applies to open links the settings they take in place, and nothing
    /// else: no link is opened, closed or reconnected.
    ///
    /// For while a radio's settings page is open. The engine holds off
    /// reconciling then, so the link is not reopened on every keystroke in a
    /// host field, but timing and TNC4 levels change nothing about the link
    /// and have to reach the TNC while the operator is setting them (the TNC4
    /// level assistant tries each gain live). A radio whose transport changed
    /// is left for the reconcile that follows when the page closes, except
    /// that a radio moved to another kind of transport lets go of its old
    /// link at once (see `retireLinksOfMovedRadios`).
    func applyInPlace(_ radios: [RadioProfile]) {
        retireLinksOfMovedRadios(radios)
        for radio in radios where radio.enabled && !radio.archived {
            guard let index = profiles.firstIndex(where: { $0.id == radio.id }),
                  profiles[index].transportSignature == radio.transportSignature,
                  let session = session(for: radio.id) else { continue }
            #if os(macOS)
            // The modem rebuilds itself for some settings outside its
            // signature (the CI-V address); those wait for the page to close.
            if let modem = session.link as? ModemRadioLink, let config = radio.modemConfig,
               config.requiresReopen(from: modem.config) { continue }
            #endif
            profiles[index] = radio
            // One link, one config: the radio that leads the link sets it.
            if profiles.first(where: { $0.linkKey == radio.linkKey })?.id == radio.id {
                update(session, from: radio)
            }
            sendTimingIfNeeded(radio)
        }
    }

    /// Closes and drops the link of every radio whose transport kind is no
    /// longer the one its link was made for, unless another radio still
    /// rides that link.
    ///
    /// For the settings page, where reconciling waits for the page to close.
    /// Switching a TNC4 radio from Serial to Bluetooth there used to leave
    /// the serial port open, and retrying if it dropped, until the operator
    /// left the page. A dropped link is not opened again by anything: the
    /// new transport's link is made by the next reconcile.
    private func retireLinksOfMovedRadios(_ radios: [RadioProfile]) {
        let moved = profiles.filter { old in
            guard let new = radios.first(where: { $0.id == old.id }) else { return false }
            return new.kind != old.kind
        }
        guard !moved.isEmpty else { return }
        hasRetiredLinks = true
        let movedIDs = Set(moved.map(\.id))
        for radio in moved {
            guard let key = assignment[radio.id]?.key else { continue }
            assignment.removeValue(forKey: radio.id)
            demux[key] = demux[key]?.filter { $0.value != radio.id }
            sentTiming.removeValue(forKey: radio.id)
            rigReceive.removeValue(forKey: radio.id)
            // Two radios on one Direwolf share a link; it stays while one
            // of them still uses it.
            guard demux[key]?.isEmpty ?? true, let session = sessions.removeValue(forKey: key) else { continue }
            demux.removeValue(forKey: key)
            outages.forget(key)
            session.close()
        }
        profiles.removeAll { movedIDs.contains($0.id) }
        refreshRadioStates()
    }

    // MARK: - KISS timing for links that do not send it

    /// Sends a radio's timing to its TNC when the operator has asked for it
    /// and the link would not do it by itself: a network TNC such as
    /// Direwolf, or a plain serial one (`RadioProfile.timingDelivery`).
    ///
    /// On the radio's own KISS port, so two radios sharing one Direwolf each
    /// set their own channel. Sent when the link comes up and whenever the
    /// values change while it is up; switching the option off sends nothing,
    /// and the TNC keeps what it was last told until it restarts.
    private func sendTimingIfNeeded(_ radio: RadioProfile, force: Bool = false) {
        guard radio.managerSendsTiming else {
            sentTiming.removeValue(forKey: radio.id)
            return
        }
        guard let session = session(for: radio.id), session.state == .connected else { return }
        let timing = radio.kissTiming
        guard force || sentTiming[radio.id] != timing else { return }
        sentTiming[radio.id] = timing
        let frames = timing.frames(port: radio.kissPort).reduce(Data(), +)
        session.send(frames) { _ in }
    }

    /// Recorded when the factory made no link though the settings looked
    /// complete: a real failure, which no check of the settings can see.
    nonisolated static let linkCouldNotBeCreated = "This radio's link could not be created."

    /// What a radio's page says about why it cannot connect, and whether its
    /// Connect is grayed out.
    ///
    /// `live` is `unsupportedReason` run now; `recorded` is what the last
    /// reconcile found. Reconciling waits while the radio's page is open, so
    /// a settings reason recorded before the operator fixed the field outlives
    /// the fix: on 2026-10-08 a saved password left the page saying "Enter
    /// the radio's network password." with Connect grayed out. Once the live
    /// check passes, only a real failure is still worth saying.
    nonisolated static func unavailableReason(live: String?, recorded: String?) -> String? {
        if let live { return live }
        return recorded == linkCouldNotBeCreated ? recorded : nil
    }

    /// Why a radio can have no link here, in the operator's words; nil when
    /// the factory should manage.
    nonisolated static func unsupportedReason(for radio: RadioProfile) -> String? {
        guard radio.kind == .modem else { return nil }
        #if os(macOS)
        if radio.modemRigLink == .lan {
            if radio.lanHost.isEmpty { return "Enter the radio's Wi-Fi address." }
            if radio.lanUsername.isEmpty { return "Enter the radio's network username." }
            // Read the password now, not the profile's remembered flag: a
            // rebuild's new code signature can leave it saved but unreadable,
            // and sending an empty password would look like a wrong one.
            switch RadioSecrets.readLANPassword(for: radio.id) {
            case .found: return nil
            case .absent: return "Enter the radio's network password."
            case .unreadable(let status):
                return KeychainStore.ReadOutcome.unreadable(status).operatorAdvice
                    ?? "The saved password could not be read. Re-enter it once."
            }
        }
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
                mobilinkdConfig: radio.mobilinkdConfig,
                timing: radio.kissTiming))
        }
        #endif
        if let ble = session.link as? KISSLinkBLE {
            ble.updateConfig(radio.bleConfig)
        }
        #if os(macOS)
        if let modem = session.link as? ModemRadioLink, let config = radio.modemConfig {
            modem.updateConfig(config)
        }
        #endif
    }

    func openAll() {
        isHeldClosed = false
        for session in sessions.values where session.state == .disconnected || session.state == .failed {
            session.open()
        }
        refreshRadioStates()
    }

    /// The operator's Disconnect: every link closes and stays closed until
    /// they connect again (see `isHeldClosed`).
    func closeAll() {
        isHeldClosed = true
        for session in sessions.values { session.close() }
        outages.removeAll()
        refreshRadioStates()
    }

    /// The machine is going to sleep. Every link goes down on purpose so the
    /// far ends see a close rather than a client that stopped answering, and
    /// every one of them stays wanted.
    ///
    /// Deliberately not `closeAll()`: that is the operator changing their mind,
    /// and a link closed that way does not come back by itself.
    func suspendAll() {
        for session in sessions.values { session.suspend() }
        refreshRadioStates()
    }

    /// Start noticing links that stay down.
    ///
    /// Explicit rather than automatic in `init`, so a test that builds a
    /// manager does not acquire a repeating timer it never asked for.
    func startWatchingOutages(interval: TimeInterval = 60) {
        guard outageTimer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOutages() }
        }
        RunLoop.main.add(timer, forMode: .common)
        outageTimer = timer
    }

    func stopWatchingOutages() {
        outageTimer?.invalidate()
        outageTimer = nil
    }

    /// Report any link that has now been down too long. Separate from the
    /// timer so it can be driven directly from a test.
    func checkOutages(now: Date = Date(), isAsleep: Bool? = nil) {
        let isAsleep = isAsleep ?? SystemPowerMonitor.shared.isAsleep
        // A sleeping Mac has every link down by definition. Reporting that
        // would be telling the operator about their own lid.
        guard !isAsleep else { return }
        for outage in outages.due(now: now) {
            guard let session = sessions[outage.key] else { continue }
            delegate?.radioManager(self, link: session, hasBeenDownFor: outage.down)
        }
    }

    /// The machine is back. Reopen everything that was up, with no backoff to
    /// serve: the disconnect was expected.
    func resumeAll() {
        // The sleep is not an outage the operator needs telling about, so the
        // clocks restart rather than reporting the hours the lid was shut.
        outages.reset(now: Date())
        // Nothing was up when the lid closed, by the operator's choice.
        guard !isHeldClosed else { return }
        for session in sessions.values { session.resume() }
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
        // A link the operator closed, or one no longer configured, is down on
        // purpose and is not an outage to report.
        if isHeldClosed || sessions[session.key] !== session {
            outages.forget(session.key)
        } else {
            outages.observe(session.key, isUp: state == .connected, now: Date())
        }
        refreshRadioStates()
        // A fresh connection is a TNC that may have restarted: tell it again.
        let carried = radios(onLink: session.key)
        if state == .connected {
            for id in carried { if let radio = profile(id) { sendTimingIfNeeded(radio, force: true) } }
        } else {
            for id in carried { sentTiming.removeValue(forKey: id) }
            // A radio that is not connected has no receive settings to show;
            // an old drift notice would offer a fix nothing can apply.
            for id in carried { rigReceive.removeValue(forKey: id) }
        }
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

    func linkSession(_ session: LinkSession, didUpdateRigReceive report: RigReceiveAudit.Report) {
        guard session.state == .connected else { return }
        for radio in radios(onLink: session.key) where rigReceive[radio] != report { rigReceive[radio] = report }
    }

    // MARK: - Radios AXTerm has set up

    /// Whether any link owes its radio settings back, so a quit knows to
    /// give the restore time (see `ModemRadioLink.close()`).
    var hasPreparedRadios: Bool {
        #if os(macOS)
        return sessions.values.contains { ($0.link as? ModemRadioLink)?.hasPreparedRadio == true }
        #else
        return false
        #endif
    }

    /// Whether any link is still closing: unkeying, putting its radio back,
    /// shutting its port.
    var isClosingRigs: Bool {
        #if os(macOS)
        return sessions.values.contains { ($0.link as? ModemRadioLink)?.isClosingRig == true }
        #else
        return false
        #endif
    }

    private func refreshRadioStates() {
        var states: [RadioID: KISSLinkState] = [:]
        for radio in profiles {
            states[radio.id] = session(for: radio.id)?.state ?? .disconnected
        }
        if states != radioStates { radioStates = states }
        #if os(macOS)
        // Told here rather than only from the window, so a station running
        // with its window closed still stops being napped when a radio comes
        // up and stops holding sleep off when the last one goes away.
        KeepAwakeController.shared.connectionChanged(
            isConnected: states.values.contains(.connected))
        #endif
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
            return KISSLinkNetwork(host: radio.host, port: UInt16(radio.port),
                                   autoReconnect: radio.tcpAutoReconnect)
        case .serial:
            #if os(macOS)
            return KISSLinkSerial(config: SerialConfig(
                devicePath: SerialDevicePathResolver.resolve(radio.serialDevicePath),
                baudRate: radio.serialBaudRate,
                autoReconnect: radio.serialAutoReconnect,
                mobilinkdConfig: radio.mobilinkdConfig,
                timing: radio.kissTiming))
            #else
            guard radio.port > 0, radio.port <= 65_535 else { return nil }
            return KISSLinkNetwork(host: radio.host, port: UInt16(radio.port),
                                   autoReconnect: radio.tcpAutoReconnect)
            #endif
        case .ble:
            return KISSLinkBLE(config: radio.bleConfig)
        case .modem:
            #if os(macOS)
            guard let config = radio.modemConfig else { return nil }
            if config.rigLink == .lan {
                guard !config.lanHost.isEmpty, !config.lanUsername.isEmpty, !config.lanPassword.isEmpty else { return nil }
                return ModemRadioLink(config: config, audio: nil)
            }
            guard !config.audioInputDeviceUID.isEmpty, !config.audioOutputDeviceUID.isEmpty else { return nil }
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
