#!/usr/bin/env swift
//
//  test_tnc4_connect.swift
//
//  Phase 1: Dump all TNC4 settings (factory defaults after reset)
//  Phase 2: Send KISS init + SABM to K0EPI-7, wait for UA
//
//  Usage: swift test_tnc4_connect.swift [dump|connect|both]
//    dump    — dump all TNC4 settings to JSON
//    connect — KISS init + SABM connection test
//    both    — dump settings then connect (default)
//

import Foundation

// MARK: - Config
let localCall = "K0EPI"
let localSSID: UInt8 = 6
let remoteCall = "K0EPI"
let remoteSSID: UInt8 = 7

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "both"

// MARK: - Find TNC4
func findDevice() -> String? {
    let preferred = "/dev/cu.usbmodem204B316146521"
    if FileManager.default.fileExists(atPath: preferred) { return preferred }
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: "/dev") {
        let devices = contents.filter { $0.hasPrefix("cu.") && $0.lowercased().contains("usbmodem") }.sorted()
        if let first = devices.first { return "/dev/\(first)" }
    }
    return nil
}

guard let devicePath = findDevice() else {
    print("❌ No TNC4 found at /dev/cu.usbmodem*")
    exit(1)
}
print("📡 Found TNC4: \(devicePath)")

// MARK: - Open & Configure Serial
let fd = Darwin.open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
guard fd >= 0 else {
    print("❌ Cannot open \(devicePath): \(String(cString: strerror(errno)))")
    exit(1)
}
defer { Darwin.close(fd); print("🔌 Closed") }

var opts = termios()
tcgetattr(fd, &opts)
cfmakeraw(&opts)
cfsetispeed(&opts, speed_t(B115200))
cfsetospeed(&opts, speed_t(B115200))
opts.c_cflag |= UInt(CS8 | CLOCAL | CREAD)
opts.c_cflag &= ~UInt(PARENB | CSTOPB | CRTSCTS)
opts.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
opts.c_cc.16 = 0; opts.c_cc.17 = 0
tcsetattr(fd, TCSANOW, &opts)
tcflush(fd, TCIOFLUSH)
var dtrRts: Int32 = 0x002 | 0x004
ioctl(fd, 0x8004746c, &dtrRts)
print("✅ Serial: 115200 8N1, DTR+RTS")

// Stabilize
Thread.sleep(forTimeInterval: 1.0)
_ = readAll(fd) // drain stale

// MARK: - Low-level Helpers
func writeKISS(_ fd: Int32, type: UInt8, payload: [UInt8]) {
    var frame: [UInt8] = [0xC0, type]
    for b in payload {
        if b == 0xC0 { frame += [0xDB, 0xDC] }
        else if b == 0xDB { frame += [0xDB, 0xDD] }
        else { frame.append(b) }
    }
    frame.append(0xC0)
    frame.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
}

func readAll(_ fd: Int32) -> [UInt8] {
    var result = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = Darwin.read(fd, &buf, buf.count)
        if n > 0 { result += buf[0..<n] } else { break }
    }
    return result
}

func readUntilQuiet(_ fd: Int32, timeout: TimeInterval = 3.0, quietPeriod: TimeInterval = 0.5) -> [UInt8] {
    var result = [UInt8]()
    let deadline = Date().addingTimeInterval(timeout)
    var lastDataTime = Date()

    while Date() < deadline {
        let chunk = readAll(fd)
        if !chunk.isEmpty {
            result += chunk
            lastDataTime = Date()
        } else if Date().timeIntervalSince(lastDataTime) > quietPeriod {
            break // No data for quietPeriod, assume done
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return result
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.prefix(256).map { String(format: "%02X", $0) }.joined(separator: " ") +
        (bytes.count > 256 ? "...(\(bytes.count))" : "")
}

func extractKISSFrames(_ bytes: [UInt8]) -> [[UInt8]] {
    var frames = [[UInt8]]()
    var i = 0
    while i < bytes.count {
        if bytes[i] == 0xC0 {
            i += 1
            while i < bytes.count && bytes[i] == 0xC0 { i += 1 }
            if i >= bytes.count { break }
            var frame = [UInt8]()
            var esc = false
            while i < bytes.count && bytes[i] != 0xC0 {
                if esc {
                    if bytes[i] == 0xDC { frame.append(0xC0) }
                    else if bytes[i] == 0xDD { frame.append(0xDB) }
                    else { frame.append(bytes[i]) }
                    esc = false
                } else if bytes[i] == 0xDB { esc = true }
                else { frame.append(bytes[i]) }
                i += 1
            }
            if !frame.isEmpty { frames.append(frame) }
        } else { i += 1 }
    }
    return frames
}

// MARK: - Command Name Lookup
let hwCommandNames: [UInt8: String] = [
    0x01: "SET_OUTPUT_GAIN", 0x02: "SET_INPUT_GAIN",
    0x03: "SET_SQUELCH_LEVEL", 0x04: "POLL_INPUT_LEVEL",
    0x06: "GET_BATTERY_LEVEL", 0x0B: "RESET",
    0x0C: "GET_OUTPUT_GAIN", 0x0D: "GET_INPUT_GAIN",
    0x10: "SET_VERBOSITY", 0x11: "GET_VERBOSITY",
    0x18: "SET_INPUT_TWIST", 0x19: "GET_INPUT_TWIST",
    0x1A: "SET_OUTPUT_TWIST", 0x1B: "GET_OUTPUT_TWIST",
    0x21: "GET_TXDELAY", 0x22: "GET_PERSIST",
    0x23: "GET_TIMESLOT", 0x24: "GET_TXTAIL",
    0x25: "GET_DUPLEX", 0x28: "GET_FIRMWARE_VERSION",
    0x29: "GET_HARDWARE_VERSION", 0x2A: "SAVE_EEPROM",
    0x2F: "GET_SERIAL_NUMBER", 0x30: "GET_MAC_ADDRESS",
    0x31: "GET_DATETIME", 0x33: "GET_ERROR_MSG",
    0x42: "GET_BT_NAME", 0x44: "GET_BT_PIN",
    0x46: "GET_BT_CONN_TRACK", 0x48: "GET_BT_MAJOR_CLASS",
    0x49: "SET_USB_POWER_ON", 0x4A: "GET_USB_POWER_ON",
    0x4B: "SET_USB_POWER_OFF", 0x4C: "GET_USB_POWER_OFF",
    0x4D: "SET_BT_POWER_OFF", 0x4E: "GET_BT_POWER_OFF",
    0x4F: "SET_PTT_CHANNEL", 0x50: "GET_PTT_CHANNEL",
    0x51: "SET_PASSALL", 0x52: "GET_PASSALL",
    0x53: "SET_RX_REV_POLARITY", 0x54: "GET_RX_REV_POLARITY",
    0x55: "SET_TX_REV_POLARITY", 0x56: "GET_TX_REV_POLARITY",
    0x77: "GET_MIN_OUTPUT_TWIST", 0x78: "GET_MAX_OUTPUT_TWIST",
    0x79: "GET_MIN_INPUT_TWIST", 0x7A: "GET_MAX_INPUT_TWIST",
    0x7B: "GET_API_VERSION", 0x7C: "GET_MIN_INPUT_GAIN",
    0x7D: "GET_MAX_INPUT_GAIN", 0x7E: "GET_CAPABILITIES",
    0x7F: "GET_ALL_VALUES",
    0x81: "EXT_GET_MODEM_TYPE", 0x82: "EXT_SET_MODEM_TYPE",
    0x83: "EXT_GET_MODEM_TYPES",
]

// Commands that return string data
let stringCommands: Set<UInt8> = [0x28, 0x29, 0x2F, 0x33, 0x42, 0x44]

// MARK: - Phase 1: Dump Settings
func dumpSettings() -> [String: Any] {
    print("\n═══════════════════════════════════")
    print("📋 DUMPING TNC4 FACTORY SETTINGS")
    print("═══════════════════════════════════\n")

    // Send GET_ALL_VALUES (0x7F)
    print("Sending GET_ALL_VALUES (0x7F)...")
    writeKISS(fd, type: 0x06, payload: [0x7F])

    // Collect all responses (TNC4 sends ~25 replies)
    let rawBytes = readUntilQuiet(fd, timeout: 5.0, quietPeriod: 1.0)
    print("Received \(rawBytes.count) bytes total\n")

    let frames = extractKISSFrames(rawBytes)
    print("Decoded \(frames.count) KISS frames:\n")

    var settings = [String: Any]()

    for frame in frames {
        guard frame.count >= 2 else { continue }
        let kissType = frame[0]
        let payload = Array(frame.dropFirst())

        if kissType == 0x06 && !payload.isEmpty {
            let cmd = payload[0]
            let data = Array(payload.dropFirst())
            let name = hwCommandNames[cmd] ?? "UNKNOWN_0x\(String(format: "%02X", cmd))"

            if stringCommands.contains(cmd) {
                let str = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? hex(data)
                print("  \(name) (0x\(String(format: "%02X", cmd))): \"\(str)\"")
                settings[name] = str
            } else if data.count == 1 {
                print("  \(name) (0x\(String(format: "%02X", cmd))): \(data[0])")
                settings[name] = Int(data[0])
            } else if data.count == 2 {
                let val = (UInt16(data[0]) << 8) | UInt16(data[1])
                print("  \(name) (0x\(String(format: "%02X", cmd))): \(val) (0x\(String(format: "%04X", val)))")
                settings[name] = Int(val)
            } else if data.count == 6 && cmd == 0x30 { // MAC address
                let mac = data.map { String(format: "%02X", $0) }.joined(separator: ":")
                print("  \(name) (0x\(String(format: "%02X", cmd))): \(mac)")
                settings[name] = mac
            } else if data.count == 7 && cmd == 0x31 { // Datetime
                let dt = data.map { String(format: "%02X", $0) }.joined(separator: "-")
                print("  \(name) (0x\(String(format: "%02X", cmd))): \(dt)")
                settings[name] = dt
            } else {
                print("  \(name) (0x\(String(format: "%02X", cmd))): [\(hex(data))]")
                settings[name] = data.map { Int($0) }
            }
        } else if kissType == 0x00 {
            // AX.25 data frame (shouldn't happen during dump, but log it)
            print("  [AX.25 DATA]: \(payload.count) bytes")
        } else {
            print("  [KISS type=0x\(String(format: "%02X", kissType))]: \(payload.count) bytes")
        }
    }

    // Save to JSON
    let jsonPath = "/Users/rwardrup/dev/AXTerm/tnc4_factory_defaults.json"
    if let jsonData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
        try? jsonData.write(to: URL(fileURLWithPath: jsonPath))
        print("\n💾 Saved to \(jsonPath)")
    }

    return settings
}

// MARK: - Phase 2: Connection Test
func connectionTest() {
    print("\n═══════════════════════════════════")
    print("🔗 CONNECTION TEST: \(localCall)-\(localSSID) → \(remoteCall)-\(remoteSSID)")
    print("═══════════════════════════════════\n")

    // Step 1: Verify TNC4 responds
    print("🔍 Verifying TNC4 is alive...")
    writeKISS(fd, type: 0x06, payload: [0x28]) // GET_FIRMWARE_VERSION
    Thread.sleep(forTimeInterval: 1.0)
    let verBytes = readAll(fd)
    if !verBytes.isEmpty {
        let frames = extractKISSFrames(verBytes)
        for f in frames {
            if f.count >= 2 && f[0] == 0x06 && f[1] == 0x28 {
                let ver = String(bytes: Array(f.dropFirst().dropFirst()), encoding: .utf8) ?? "?"
                print("   ✅ Firmware: \(ver)")
            }
        }
    } else {
        print("   ❌ NO RESPONSE to GET_FIRMWARE_VERSION!")
        print("   TNC4 may not be in KISS mode. Try power-cycling.")
        return
    }

    // Step 2: KISS init
    print("\n📤 KISS init...")
    writeKISS(fd, type: 0x05, payload: [0x00]); Thread.sleep(forTimeInterval: 0.1) // Duplex=0
    writeKISS(fd, type: 0x02, payload: [0x3F]); Thread.sleep(forTimeInterval: 0.1) // P=63
    writeKISS(fd, type: 0x03, payload: [0x00]); Thread.sleep(forTimeInterval: 0.1) // Slot=0
    writeKISS(fd, type: 0x01, payload: [30]);   Thread.sleep(forTimeInterval: 0.1) // TXDelay=30
    print("   ⚡ RESET (start demodulator)...")
    writeKISS(fd, type: 0x06, payload: [0x0B])
    print("   Waiting 3s for demodulator...")
    Thread.sleep(forTimeInterval: 3.0)
    let drainBytes = readAll(fd)
    if !drainBytes.isEmpty {
        print("   Drained \(drainBytes.count) post-init bytes: \(hex(drainBytes))")
    }

    // Step 3: Listen 10s for any RF traffic
    print("\n👂 Listening 10s for ANY RF traffic...")
    var heard = [UInt8]()
    let listenEnd = Date().addingTimeInterval(10.0)
    while Date() < listenEnd {
        let chunk = readAll(fd)
        if !chunk.isEmpty {
            heard += chunk
            print("   RX \(chunk.count) bytes: \(hex(chunk))")
            let frames = extractKISSFrames(heard)
            for f in frames {
                let t = f[0]
                if t == 0x00 && f.count > 15 {
                    let ctl = f[15] // [type, dest(7), src(7), ctl]
                    let src = decodeAddr(Array(f.dropFirst()), offset: 7)
                    let dst = decodeAddr(Array(f.dropFirst()), offset: 0)
                    print("   🔷 AX.25: \(src) → \(dst) \(describeControl(ctl))")
                }
            }
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    print("   Total heard: \(heard.count) bytes")
    if heard.isEmpty {
        print("   ⚠️  NOTHING received — demodulator may not be running or frequency is silent")
    }

    // Step 4: Send SABM with retries
    print("\n📤 Sending SABM...")
    var sabm = [UInt8]()
    sabm += encodeAddress(remoteCall, ssid: remoteSSID, isLast: false, cr: true)
    sabm += encodeAddress(localCall, ssid: localSSID, isLast: true, cr: false)
    sabm.append(0x3F) // SABM|P
    print("   SABM: \(hex(sabm))")
    writeKISS(fd, type: 0x00, payload: sabm)

    var allRX = [UInt8]()
    var gotUA = false
    var gotDM = false
    let connDeadline = Date().addingTimeInterval(30.0)
    var lastTx = Date()

    while Date() < connDeadline {
        if Date().timeIntervalSince(lastTx) >= 5.0 {
            print("   🔄 Retransmit SABM...")
            writeKISS(fd, type: 0x00, payload: sabm)
            lastTx = Date()
        }
        let chunk = readAll(fd)
        if !chunk.isEmpty {
            allRX += chunk
            print("   📥 RX \(chunk.count) bytes: \(hex(chunk))")
            let frames = extractKISSFrames(allRX)
            for f in frames where f.count > 15 && f[0] == 0x00 {
                let ctl = f[15]
                let src = decodeAddr(Array(f.dropFirst()), offset: 7)
                let dst = decodeAddr(Array(f.dropFirst()), offset: 0)
                print("   🔷 \(src) → \(dst) \(describeControl(ctl))")
                if (ctl & 0xEF) == 0x63 { gotUA = true; print("   🎉 UA!"); break }
                if (ctl & 0xEF) == 0x0F { gotDM = true; print("   ❌ DM!"); break }
            }
            if gotUA || gotDM { break }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    // Clean up
    if gotUA {
        var disc = [UInt8]()
        disc += encodeAddress(remoteCall, ssid: remoteSSID, isLast: false, cr: true)
        disc += encodeAddress(localCall, ssid: localSSID, isLast: true, cr: false)
        disc.append(0x53) // DISC|P
        writeKISS(fd, type: 0x00, payload: disc)
        Thread.sleep(forTimeInterval: 2.0)
        _ = readAll(fd)
    }

    print("\n═══════════════════════════════════")
    print("📊 RESULTS")
    print("   RX bytes: \(allRX.count)")
    print("   UA: \(gotUA ? "✅" : "❌")  DM: \(gotDM ? "YES" : "NO")")
    print("═══════════════════════════════════")
}

// MARK: - AX.25 Helpers
func encodeAddress(_ call: String, ssid: UInt8, isLast: Bool, cr: Bool) -> [UInt8] {
    var bytes = [UInt8]()
    let chars = Array(call.uppercased().utf8)
    for i in 0..<6 { bytes.append(i < chars.count ? (chars[i] << 1) : 0x40) }
    var s = ((ssid & 0x0F) << 1) | 0x60
    if isLast { s |= 0x01 }
    if cr { s |= 0x80 }
    bytes.append(s)
    return bytes
}

func decodeAddr(_ bytes: [UInt8], offset: Int) -> String {
    guard offset + 7 <= bytes.count else { return "?" }
    var call = ""
    for i in 0..<6 { let c = bytes[offset+i] >> 1; if c != 0x20 { call.append(Character(UnicodeScalar(c))) } }
    return "\(call)-\((bytes[offset+6] >> 1) & 0x0F)"
}

func describeControl(_ ctl: UInt8) -> String {
    let m = ctl & 0xEF
    switch m {
    case 0x2F: return "SABM\(ctl & 0x10 != 0 ? "(P)" : "")"
    case 0x63: return "UA\(ctl & 0x10 != 0 ? "(F)" : "")"
    case 0x0F: return "DM\(ctl & 0x10 != 0 ? "(F)" : "")"
    case 0x43: return "DISC\(ctl & 0x10 != 0 ? "(P)" : "")"
    case 0x03: return "UI"
    default:
        if (ctl & 0x01) == 0 { return "I(ns=\(ctl >> 1 & 7),nr=\(ctl >> 5 & 7))" }
        if (ctl & 0x03) == 0x01 { return ["RR","RNR","REJ","SREJ"][Int((ctl>>2)&3)] + "(nr=\(ctl>>5&7))" }
        return "U(0x\(String(format: "%02X", ctl)))"
    }
}

// MARK: - Run
if mode == "dump" || mode == "both" {
    let _ = dumpSettings()
}
if mode == "connect" || mode == "both" {
    connectionTest()
}

exit(0)
