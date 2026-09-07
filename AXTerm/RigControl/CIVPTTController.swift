import Foundation

/// Keys the radio with the CI-V transmit command.
///
/// The modem plays no audio until the radio has acknowledged the key-down,
/// and every failure path — a rejected command, a timeout, the port
/// closing, the watchdog — ends with a key-up. A transmitter left keyed is
/// the one fault a modem must not have.
nonisolated final class CIVPTTController: PTTController, @unchecked Sendable {

    let client: CIVClient
    /// Longest the transmitter may stay keyed before it is forced off.
    let maxTransmitSeconds: TimeInterval
    /// Roughly one CI-V round trip.
    var keyUpLatencyHint: TimeInterval { 0.03 }

    /// Key state changes, for the log and the PTT dot.
    var onTransition: (@Sendable (_ keyed: Bool, _ note: String?) -> Void)?

    private let lock = NSLock()
    private var keyed = false
    private var watchdog: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.axterm.civ.ptt")

    init(client: CIVClient, maxTransmitSeconds: TimeInterval = 30) {
        self.client = client
        self.maxTransmitSeconds = maxTransmitSeconds
        client.onTransportState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .closed, .failed:
                // Nothing can be sent now; what we can do is stop believing
                // the radio is keyed, and say so.
                if self.markKeyed(false) { self.onTransition?(false, "CI-V port lost while keyed") }
            case .opening, .open:
                break
            }
        }
    }

    var isKeyed: Bool { lock.withLock { keyed } }

    func setTransmit(_ on: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        Task { [self] in
            if on {
                do {
                    try await client.setPTT(true)
                    markKeyed(true)
                    armWatchdog()
                    onTransition?(true, nil)
                    completion(nil)
                } catch {
                    // Whatever happened, make sure the radio is not keyed.
                    try? await client.setPTT(false)
                    completion(error)
                }
            } else {
                disarmWatchdog()
                var failure: Error?
                do {
                    try await client.setPTT(false)
                } catch {
                    // One retry: a lost key-up is worth a second command.
                    do { try await client.setPTT(false) } catch let second { failure = second }
                }
                markKeyed(false)
                onTransition?(false, failure.map { "key-up failed: \($0)" })
                completion(failure)
            }
        }
    }

    /// Force the transmitter off now, whatever the modem thinks.
    func forceKeyUp(reason: String) {
        disarmWatchdog()
        Task { [self] in
            try? await client.setPTT(false)
            try? await client.setPTT(false)
            markKeyed(false)
            onTransition?(false, reason)
        }
    }

    @discardableResult
    private func markKeyed(_ value: Bool) -> Bool {
        lock.withLock {
            let changed = keyed != value
            keyed = value
            return changed
        }
    }

    private func armWatchdog() {
        disarmWatchdog()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isKeyed else { return }
            self.forceKeyUp(reason: "PTT watchdog: keyed for \(Int(self.maxTransmitSeconds)) s, forced off")
        }
        lock.withLock { watchdog = item }
        queue.asyncAfter(deadline: .now() + maxTransmitSeconds, execute: item)
    }

    private func disarmWatchdog() {
        lock.withLock {
            watchdog?.cancel()
            watchdog = nil
        }
    }
}

/// Keys the radio by raising RTS or DTR on the CI-V serial port — the
/// radio's "USB SEND" set to that line.
nonisolated final class SerialLinePTTController: PTTController, @unchecked Sendable {
    enum Line: Sendable { case rts, dtr }

    let transport: CIVTransport
    let line: Line
    let maxTransmitSeconds: TimeInterval
    var keyUpLatencyHint: TimeInterval { 0.005 }
    var onTransition: (@Sendable (_ keyed: Bool, _ note: String?) -> Void)?

    private let lock = NSLock()
    private var keyed = false
    private var watchdog: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.axterm.serial.ptt")

    init(transport: CIVTransport, line: Line, maxTransmitSeconds: TimeInterval = 30) {
        self.transport = transport
        self.line = line
        self.maxTransmitSeconds = maxTransmitSeconds
    }

    var isKeyed: Bool { lock.withLock { keyed } }

    func setTransmit(_ on: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        guard transport.state == .open else {
            completion(CIVTransportError.notOpen)
            return
        }
        switch line {
        case .rts: transport.setModemLines(dtr: nil, rts: on)
        case .dtr: transport.setModemLines(dtr: on, rts: nil)
        }
        lock.withLock { keyed = on }
        if on {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.isKeyed else { return }
                self.setTransmit(false) { _ in }
                self.onTransition?(false, "PTT watchdog: keyed for \(Int(self.maxTransmitSeconds)) s, forced off")
            }
            lock.withLock { watchdog?.cancel(); watchdog = item }
            queue.asyncAfter(deadline: .now() + maxTransmitSeconds, execute: item)
        } else {
            lock.withLock { watchdog?.cancel(); watchdog = nil }
        }
        onTransition?(on, nil)
        completion(nil)
    }
}
