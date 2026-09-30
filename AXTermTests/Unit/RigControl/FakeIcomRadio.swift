import Foundation
@testable import AXTerm

/// An IC-705 that remembers its settings: reads report what the last write
/// set, `06` clears the data flag as the real radio does, and individual
/// settings can be made to refuse writes (NG) or ignore reads. For tests
/// that follow a radio through prepare, drift, fix and restore, where a
/// scripted reply per command cannot keep up.
///
/// Settings are keyed by command and subcommand in hex: `"04"` is the mode
/// and filter, `"1A06"` data mode, `"1A05:0119"` a menu item, `"11"` the
/// attenuator, `"1402"` RF gain, `"1641"` the auto notch, and so on.
nonisolated final class FakeIcomRadio: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [UInt8]]
    private var _refusedWrites: Set<String> = []
    private var _ignoredReads: Set<String> = []
    private var _malformedReads: [String: [UInt8]] = [:]

    /// An IC-705 as an operator might leave it after a voice session: USB on
    /// FIL2, data off, the microphone as the data input, the notch and NR on,
    /// TSQL on, RF gain half, the attenuator in.
    static func voiceSetup() -> [String: [UInt8]] {
        [
            "04": [0x01, 0x02],                  // USB, FIL2
            "1A06": [0x00, 0x00],                // data off
            "1A05:0119": [0x00],                 // DATA MOD = MIC
            "1A05:0111": [0x01],                 // USB AF squelch on
            "1A05:0125": [0x01],                 // USB SEND = something else
            "1A05:0131": [0x01],                 // CI-V transceive on
            "1A05:0038": [0x01], "1A05:0039": [0x01], "1A05:0041": [0x01], "1A05:0042": [0x01],
            "11": [0x20],                        // 20 dB attenuator
            "1402": [0x01, 0x28],                // RF gain 128
            "1403": [0x00, 0x50],                // squelch 50
            "1640": [0x01],                      // NR on
            "1622": [0x00],                      // NB off
            "1641": [0x01],                      // auto notch on
            "1648": [0x00],                      // manual notch off
            "165D": [0x02],                      // TSQL
            "1602": [0x01],                      // P.AMP1
        ]
    }

    /// An IC-705 already set up for 1200 bd packet over USB.
    static func packetSetup() -> [String: [UInt8]] {
        [
            "04": [0x05, 0x01], "1A06": [0x01, 0x01],
            "1A05:0119": [0x01], "1A05:0111": [0x00], "1A05:0125": [0x00], "1A05:0131": [0x00],
            "1A05:0038": [0x00], "1A05:0039": [0x00], "1A05:0041": [0x00], "1A05:0042": [0x00],
            "11": [0x00], "1402": [0x02, 0x55], "1403": [0x00, 0x00],
            "1640": [0x00], "1622": [0x00], "1641": [0x00], "1648": [0x00], "165D": [0x00], "1602": [0x01],
        ]
    }

    init(_ values: [String: [UInt8]] = FakeIcomRadio.voiceSetup()) {
        self.values = values
    }

    subscript(key: String) -> [UInt8]? {
        get { lock.withLock { values[key] } }
        set { lock.withLock { values[key] = newValue } }
    }

    var snapshot: [String: [UInt8]] { lock.withLock { values } }

    func refuseWrites(to key: String) { _ = lock.withLock { _refusedWrites.insert(key) } }
    func ignoreReads(of key: String) { _ = lock.withLock { _ignoredReads.insert(key) } }
    /// Answer reads of `key` with these data bytes instead of the value.
    func answerReads(of key: String, with data: [UInt8]) { lock.withLock { _malformedReads[key] = data } }

    /// The responder to hand a `FakeCIVTransport`.
    var responder: @Sendable (CIVFrame) -> [UInt8]? { { [self] frame in self.respond(frame) } }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }

    func respond(_ frame: CIVFrame) -> [UInt8]? {
        let command = frame.command, sub = frame.subcommand, data = frame.data
        switch (command, sub) {
        case (0x19, 0x00): return FakeCIVTransport.reply(0x19, 0x00, [0xA4])
        case (0x03, _): return FakeCIVTransport.reply(0x03, nil, CIVBCD.frequencyBytes(hz: 144_390_000))
        case (0x15, 0x01): return FakeCIVTransport.reply(0x15, 0x01, [0x01])
        case (0x15, 0x02): return FakeCIVTransport.reply(0x15, 0x02, [0x00, 0x40])
        case (0x1C, 0x00): return data.isEmpty ? FakeCIVTransport.reply(0x1C, 0x00, [0x00]) : FakeCIVTransport.ok
        case (0x27, _): return FakeCIVTransport.ok
        default: break
        }
        // Mode: read `04`, set `06`.
        if command == 0x06 {
            return write("04", data.count == 1 ? data + [0x01] : data) {
                // Setting the mode clears the data flag on an Icom.
                self.values["1A06"] = [0x00, 0x00]
            }
        }
        let key: String
        let isRead: Bool
        let payload: [UInt8]
        if command == 0x1A, sub == 0x05 {
            guard data.count >= 2 else { return FakeCIVTransport.ng }
            key = "1A05:" + Self.hex(Array(data.prefix(2)))
            isRead = data.count == 2
            payload = Array(data.dropFirst(2))
        } else {
            key = Self.hex([command] + (sub.map { [$0] } ?? []))
            isRead = data.isEmpty
            payload = data
        }
        if isRead {
            let (ignored, malformed, value) = lock.withLock { (_ignoredReads.contains(key), _malformedReads[key], values[key]) }
            if ignored { return nil }
            let echo: [UInt8] = command == 0x1A && sub == 0x05 ? Array(data.prefix(2)) : []
            if let malformed { return FakeCIVTransport.reply(command, sub, echo + malformed) }
            guard let value else { return FakeCIVTransport.ng }
            return FakeCIVTransport.reply(command, sub, echo + value)
        }
        return write(key, payload)
    }

    private func write(_ key: String, _ value: [UInt8], also: (() -> Void)? = nil) -> [UInt8] {
        lock.withLock {
            if _refusedWrites.contains(key) { return FakeCIVTransport.ng }
            values[key] = value
            also?()
            return FakeCIVTransport.ok
        }
    }
}
