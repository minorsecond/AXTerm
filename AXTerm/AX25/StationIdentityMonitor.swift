import Foundation

/// Detects another station transmitting under this station's callsign-SSID.
///
/// Two AXTerm instances pointed at one Direwolf is a normal thing to end up
/// with — a desktop and a laptop on the same LAN, or a Mac and an iPad both
/// reaching the same TNC over the network. Direwolf happily accepts both KISS
/// clients and serialises their transmissions, so the *radio* is fine.
///
/// What is not fine is both of them using the same callsign-SSID. AX.25
/// connected mode keeps per-link state — send and receive sequence numbers, a
/// retry timer, a window — and that state assumes exactly one station answers
/// to an address. With two:
///
/// - both answer a SABM, so the far end gets two UAs and resets
/// - both acknowledge I-frames, so V(S)/V(R) diverge from the peer's
/// - a session one device opened is torn down by the other's DISC
/// - a Winlink P2P listener on each answers the same inbound call
///
/// None of that produces a clean error. It produces sessions that mysteriously
/// drop, retries that never resolve, and mail that half-arrives — which is
/// exactly the kind of failure an operator burns an afternoon on. So this
/// watches for the signature and says so plainly.
///
/// This is *detection*, not prevention. AX.25 has no way to stop another
/// station using an address, and neither does Direwolf. The fix is for the
/// operator to change one device's SSID, and the point of this type is to tell
/// them that is what happened.
nonisolated final class StationIdentityMonitor: @unchecked Sendable {

    /// What was seen, and the evidence for it.
    struct Collision: Equatable, Sendable {
        /// The address being used by more than one station.
        let callsign: String
        /// Where the offending frame was going, for the operator to recognise.
        let destination: String
        let frameType: String
        let at: Date

        /// Stated so the operator can act, not merely be alarmed.
        var explanation: String {
            """
            Another station on this channel is transmitting as \(callsign).

            A \(frameType) frame addressed to \(destination) arrived from \(callsign), and this station did not send it. The usual cause is a second AXTerm — or another client — sharing this TNC with the same callsign and SSID.

            AX.25 connected mode keeps sequence numbers and timers per link and assumes one station answers to an address. With two, sessions drop for no visible reason, retries never resolve, and both stations answer the same call.

            Give one of them a different SSID (Settings → General → Callsign). Any unused SSID will do; the two are then separate stations and both can share the TNC safely.
            """
        }
    }

    /// How long a transmitted frame stays recognisable as our own echo.
    ///
    /// Generous on purpose: a digipeated frame comes back after the
    /// digipeater's own channel access, which on a busy channel is seconds,
    /// not milliseconds. Too short a window turns every digipeated
    /// transmission into a false alarm.
    static let echoWindow: TimeInterval = 30

    /// Repeat warnings no more often than this. A collision produces a frame
    /// every few seconds; the operator needs telling once, not continuously.
    static let reportInterval: TimeInterval = 300

    private let lock = NSLock()
    /// Fingerprints of what we sent, with the time we sent it.
    private var sentFingerprints: [Int: Date] = [:]
    private var lastReportedAt: Date?

    init() {}

    // MARK: - Recording our own transmissions

    /// Remembers a frame this station transmitted.
    ///
    /// Called with the frame's *identity*, not its bytes, because the bytes
    /// change in flight: a digipeater sets the has-been-repeated bit on the
    /// hop it serviced, so the frame that comes back is not byte-identical to
    /// the one that went out. Fingerprinting the invariant part — who, to
    /// whom, which control field, what payload — recognises our own echo
    /// through a digipeater, which byte comparison would not.
    func recordTransmitted(source: String, destination: String,
                           control: UInt8, info: Data, at now: Date = Date()) {
        let key = Self.fingerprint(source: source, destination: destination,
                                   control: control, info: info)
        lock.lock()
        defer { lock.unlock() }
        sentFingerprints[key] = now
        pruneLocked(now: now)
    }

    // MARK: - Inspecting what arrives

    /// Returns a collision when a received frame carries our own address as
    /// its source and is not one of ours coming back.
    ///
    /// - Parameter ownCallsign: this station's callsign with SSID, exactly as
    ///   it is transmitted. Compared case-insensitively; an empty value
    ///   disables detection, since a station with no callsign set has no
    ///   identity to collide with.
    func inspectReceived(source: String?, destination: String?,
                         control: UInt8, info: Data,
                         ownCallsign: String, frameType: String,
                         at now: Date = Date()) -> Collision? {
        let own = Self.normalize(ownCallsign)
        guard !own.isEmpty, let source, Self.normalize(source) == own else { return nil }

        let key = Self.fingerprint(source: source, destination: destination ?? "",
                                   control: control, info: info)

        lock.lock()
        // Our own frame coming back — directly, or repeated by a digipeater.
        if let sentAt = sentFingerprints[key], now.timeIntervalSince(sentAt) <= Self.echoWindow {
            lock.unlock()
            return nil
        }
        // Report at most once per interval: a collision emits a frame every
        // few seconds and the operator needs telling once.
        if let last = lastReportedAt, now.timeIntervalSince(last) < Self.reportInterval {
            lock.unlock()
            return nil
        }
        lastReportedAt = now
        lock.unlock()

        return Collision(callsign: own,
                         destination: destination.map(Self.normalize) ?? "an unknown station",
                         frameType: frameType,
                         at: now)
    }

    /// Forgets everything. Used when the callsign changes, so frames sent
    /// under the old identity cannot mask a real collision under the new one.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        sentFingerprints.removeAll()
        lastReportedAt = nil
    }

    // MARK: - Internals

    /// Identity of a frame, ignoring what a digipeater rewrites.
    ///
    /// Deliberately excludes the via path: the has-been-repeated bits are
    /// exactly what changes between transmission and echo, and including them
    /// would make every digipeated frame look like somebody else's.
    static func fingerprint(source: String, destination: String,
                            control: UInt8, info: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(normalize(source))
        hasher.combine(normalize(destination))
        hasher.combine(control)
        hasher.combine(info)
        return hasher.finalize()
    }

    static func normalize(_ callsign: String) -> String {
        callsign.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private func pruneLocked(now: Date) {
        guard sentFingerprints.count > 512 else { return }
        sentFingerprints = sentFingerprints.filter {
            now.timeIntervalSince($0.value) <= Self.echoWindow
        }
    }
}
