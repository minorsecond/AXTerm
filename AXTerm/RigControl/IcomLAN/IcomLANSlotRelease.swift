import Foundation
import Darwin

/// Taking the IC-705's single client slot back at connect, instead of waiting
/// for it to lapse.
///
/// The radio serves one logged-in client at a time and keys that session on the
/// client's session ID, the `senderID` carried in every packet header. When a
/// client goes away (a quit, a crash, a dropped network) the radio keeps the
/// slot for tens of seconds and refuses a fresh login the whole time, in a reply
/// byte-for-byte identical to the one it sends for a wrong password. AXTerm used
/// to absorb that by resending the login on a 2.5-second ladder until the slot
/// timed out, which is why a relaunch sat for several seconds before the 705
/// came up while Direwolf, a plain TCP server with no such slot, connected at
/// once.
///
/// A `disconnect` (0x05) carrying a session's IDs tells the radio that session
/// is over, and the radio releases it. So if we remember the IDs of the session
/// we last held on a radio, the next launch can fire that disconnect first and
/// reclaim the slot immediately rather than waiting it out. The release names
/// our own prior session by ID, so it frees our slot and leaves any other client
/// that legitimately holds one alone.
///
/// The session-health capture in `Docs/IcomLANSessionHealth.md` records the
/// handshake this fits into: `disconnect` is the same 0x05 control packet a
/// clean close sends, matched on the sender/receiver IDs in its header.
nonisolated enum IcomLANSlotRelease {

    /// One UDP stream of a session we held: enough to address a `disconnect`
    /// at it. The radio runs the control, CI-V (serial) and audio streams
    /// separately and can keep the CI-V stream attached to a dead session
    /// while granting a new one audio, so all of them have to be released, not
    /// just control.
    struct Endpoint: Codable, Equatable {
        var localID: UInt32
        var remoteID: UInt32
        var sourcePort: UInt16
        /// The radio-side port this stream talks to (control 50001, CI-V 50002,
        /// audio 50003).
        var radioPort: UInt16
    }

    /// What we keep about the last session we held on a given radio: every
    /// stream we can address, and when we last had it so a slot that has long
    /// since lapsed on its own is left alone.
    struct Memory: Codable, Equatable {
        var streams: [Endpoint]
        /// Seconds since the reference date, refreshed whenever we hold or
        /// leave the session, so recency measures from when we last had it.
        var savedAt: TimeInterval
    }

    /// The radio holds a vacated slot for tens of seconds. Past this it has
    /// certainly lapsed, so skip the release and its settle rather than pay for
    /// a session that is already gone.
    static let reclaimWindow: TimeInterval = 90

    /// How long to let the radio act on the release before logging in again. The
    /// disconnect is unacknowledged UDP; a beat covers its flight and the
    /// radio's own teardown, and it is far short of the fifteen seconds a
    /// passive wait used to cost.
    static let settleAfterRelease: TimeInterval = 0.3

    private static func key(for host: String) -> String { "icomLAN.lastSession." + host }

    /// Record the streams we hold on `host`. A stream whose remote ID is zero
    /// or whose source port is unknown never really came up, so it is dropped;
    /// if nothing remains there is nothing to reclaim and nothing is stored.
    static func remember(host: String, streams: [Endpoint],
                         now: TimeInterval = Date.timeIntervalSinceReferenceDate,
                         defaults: UserDefaults = .standard) {
        let usable = streams.filter { $0.remoteID != 0 && $0.sourcePort != 0 }
        guard !usable.isEmpty else { return }
        let memory = Memory(streams: usable, savedAt: now)
        if let data = try? JSONEncoder().encode(memory) {
            defaults.set(data, forKey: key(for: host))
        }
    }

    static func recall(host: String, defaults: UserDefaults = .standard) -> Memory? {
        guard let data = defaults.data(forKey: key(for: host)) else { return nil }
        return try? JSONDecoder().decode(Memory.self, from: data)
    }

    static func forget(host: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: host))
    }

    /// One disconnect ready to send: the bytes, and where they go from and to.
    struct ReleasePacket: Equatable {
        var bytes: Data
        var radioPort: UInt16
        var fromPort: UInt16
    }

    /// The disconnects that release a remembered session — one per stream, so
    /// the CI-V and audio streams are freed, not just control. Each is a
    /// `disconnect` (0x05) naming that stream's own session IDs, addressed to
    /// its radio port and sent from the source port the radio knew it by.
    static func releasePackets(for memory: Memory) -> [ReleasePacket] {
        memory.streams.map { stream in
            ReleasePacket(bytes: IcomLAN.control(.disconnect, local: stream.localID, remote: stream.remoteID),
                          radioPort: stream.radioPort, fromPort: stream.sourcePort)
        }
    }

    /// Whether a remembered session is recent enough that the radio may still be
    /// holding its slot, and so worth releasing. A record from the future, from a
    /// clock that stepped back, is treated as current rather than ignored.
    static func isReclaimable(_ memory: Memory, now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Bool {
        now - memory.savedAt <= reclaimWindow
    }

    /// Fire a targeted disconnect for the session we last held on this radio,
    /// when it was recent enough that the radio may still be holding it. Returns
    /// whether a release was sent, so the caller knows to give the radio a short
    /// settle before it logs in. Best-effort throughout: any failure just means
    /// the connect falls back to the login retry ladder, exactly as before.
    @discardableResult
    static func reclaim(host: String,
                        now: TimeInterval = Date.timeIntervalSinceReferenceDate,
                        defaults: UserDefaults = .standard) -> Bool {
        guard AppEnvironment.mayConnect(to: host) else { return false }
        guard let memory = recall(host: host, defaults: defaults) else { return false }
        guard isReclaimable(memory, now: now) else { return false }
        var sentAny = false
        for release in releasePackets(for: memory) {
            if Self.sendDatagram(release.bytes, host: host, port: release.radioPort, fromPort: release.fromPort) {
                sentAny = true
            }
        }
        return sentAny
    }

    /// Send one datagram twice (UDP drops silently) from a fixed source port
    /// when it is free, so the radio can match it to the old session by source
    /// as well as by the IDs it carries. The source that held the port is gone
    /// by the time this runs, so the bind almost always lands; when it does not,
    /// the ephemeral fallback still carries the IDs that name the session.
    @discardableResult
    private static func sendDatagram(_ data: Data, host: String, port: UInt16, fromPort: UInt16) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return false }
        defer { freeaddrinfo(result) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Reuse the old source port when we can; it is almost certainly free
        // (the process that held it has exited), and a match on source helps the
        // radio recognise the session. If the bind fails, macOS picks an
        // ephemeral port and the packet's own IDs still name the session.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = fromPort.bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        _ = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        var sent = false
        for _ in 0..<2 {
            let n = data.withUnsafeBytes { raw in
                sendto(fd, raw.baseAddress, raw.count, 0, info.pointee.ai_addr, info.pointee.ai_addrlen)
            }
            if n > 0 { sent = true }
        }
        return sent
    }
}
