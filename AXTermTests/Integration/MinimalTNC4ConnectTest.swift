//
//  MinimalTNC4ConnectTest.swift
//  AXTermTests
//
//  Minimal from-scratch test: POSIX serial → KISS → AX.25 SABM → K0EPI-7 → UA
//  No PacketEngine, no SessionCoordinator, no KISSLink abstraction.
//  Just raw bytes, informed by the TNC4 firmware source.
//

import XCTest

final class MinimalTNC4ConnectTest: XCTestCase {

    // MARK: - Config

    private let localCall = "K0EPI"
    private let localSSID: UInt8 = 6
    private let remoteCall = "K0EPI"
    private let remoteSSID: UInt8 = 7
    private let baudRate = speed_t(B115200)

    private var fd: Int32 = -1

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()

        guard FileManager.default.fileExists(atPath: "/tmp/axterm_rf_tests_enabled") else {
            throw XCTSkip("RF tests disabled — use run_rf_tests.sh")
        }

        let path = findTNC4Device()
        guard let path else {
            throw XCTSkip("No TNC4 found at /dev/cu.usbmodem*")
        }

        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw XCTSkip("Cannot open \(path): \(String(cString: strerror(errno)))")
        }

        configureSerial(fd)
        NSLog("[MINIMAL] Opened %@ fd=%d", path, fd)
    }

    override func tearDown() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        super.tearDown()
    }

    // MARK: - The Test

    /// From-scratch connection: open serial, send KISS init, send SABM, wait for UA.
    /// This test bypasses ALL AXTerm code to verify the hardware/protocol path works.
    func testMinimalConnectToK0EPI7() throws {

        // Step 1: Send minimal KISS init (from firmware analysis)
        // Duplex=0 (half duplex, required for RX frame forwarding)
        writeKISS(fd, type: 0x05, payload: [0x00])
        Thread.sleep(forTimeInterval: 0.05)

        // Persistence=63 (25%)
        writeKISS(fd, type: 0x02, payload: [0x3F])
        Thread.sleep(forTimeInterval: 0.05)

        // Slot time=0
        writeKISS(fd, type: 0x03, payload: [0x00])
        Thread.sleep(forTimeInterval: 0.05)

        // TX Delay=30 (300ms)
        writeKISS(fd, type: 0x01, payload: [30])
        Thread.sleep(forTimeInterval: 0.05)

        // CRITICAL: Send RESET (0x0B) via Hardware command (type=0x06)
        // This is the ONLY way to start the demodulator per firmware analysis.
        writeKISS(fd, type: 0x06, payload: [0x0B])
        NSLog("[MINIMAL] Sent KISS init + RESET. Waiting 3s for demodulator startup...")
        Thread.sleep(forTimeInterval: 3.0)

        // Drain any init response bytes
        let initBytes = readAllAvailable(fd)
        NSLog("[MINIMAL] Init response: %d bytes: %@", initBytes.count, hexDump(initBytes))

        // Step 2: Build AX.25 SABM frame
        let sabm = buildSABM(
            dest: remoteCall, destSSID: remoteSSID,
            src: localCall, srcSSID: localSSID
        )
        NSLog("[MINIMAL] SABM frame (%d bytes): %@", sabm.count, hexDump(sabm))

        // Step 3: Send SABM via KISS DATA frame (type=0x00)
        writeKISS(fd, type: 0x00, payload: sabm)
        NSLog("[MINIMAL] SABM sent. Waiting for UA...")

        // Step 4: Wait for response (up to 15s, polling every 100ms)
        var allRX = Data()
        var gotUA = false
        var gotDM = false
        let deadline = Date().addingTimeInterval(15.0)

        while Date() < deadline {
            let chunk = readAllAvailable(fd)
            if !chunk.isEmpty {
                allRX.append(contentsOf: chunk)
                NSLog("[MINIMAL] RX %d bytes: %@", chunk.count, hexDump(chunk))

                // Try to extract KISS frames
                let kissFrames = extractKISSFrames(from: allRX)
                for kf in kissFrames {
                    let kissType = kf.first ?? 0xFF
                    let ax25Payload = Array(kf.dropFirst())

                    if kissType == 0x00 && ax25Payload.count >= 15 {
                        // AX.25 frame: check control byte at offset 14
                        let ctl = ax25Payload[14]
                        let frameTypeStr = describeControlByte(ctl)
                        NSLog("[MINIMAL] AX.25 frame: ctl=0x%02X (%@) %d bytes", ctl, frameTypeStr, ax25Payload.count)

                        // Decode addresses
                        let (destAddr, srcAddr) = decodeAddresses(Array(ax25Payload))
                        NSLog("[MINIMAL]   %@ > %@", srcAddr, destAddr)

                        // UA = 0x63, with F bit = 0x73
                        if (ctl & 0xEF) == 0x63 {
                            NSLog("[MINIMAL] *** GOT UA! Connection accepted! ***")
                            gotUA = true

                            // Send DISC to clean up
                            let disc = buildDISC(
                                dest: remoteCall, destSSID: remoteSSID,
                                src: localCall, srcSSID: localSSID
                            )
                            writeKISS(fd, type: 0x00, payload: disc)
                            NSLog("[MINIMAL] Sent DISC to clean up")
                            break
                        }

                        // DM = 0x0F, with F bit = 0x1F
                        if (ctl & 0xEF) == 0x0F {
                            NSLog("[MINIMAL] *** GOT DM! Connection refused ***")
                            gotDM = true
                            break
                        }
                    } else if kissType == 0x06 {
                        // Hardware response (telemetry)
                        NSLog("[MINIMAL] Hardware/telemetry response: %d bytes", ax25Payload.count)
                    }
                }
                if gotUA || gotDM { break }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Step 5: Report
        NSLog("[MINIMAL] === RESULTS ===")
        NSLog("[MINIMAL] Total RX: %d bytes", allRX.count)
        NSLog("[MINIMAL] Full RX hex: %@", hexDump(allRX))
        NSLog("[MINIMAL] UA received: %@", gotUA ? "YES" : "NO")
        NSLog("[MINIMAL] DM received: %@", gotDM ? "YES" : "NO")

        if gotDM {
            throw XCTSkip("K0EPI-7 sent DM (busy or not accepting)")
        }
        XCTAssertTrue(gotUA, "Should receive UA from K0EPI-7")
    }

    // MARK: - Serial Helpers

    private func findTNC4Device() -> String? {
        let preferred = "/dev/cu.usbmodem204B316146521"
        if FileManager.default.fileExists(atPath: preferred) { return preferred }

        if let contents = try? FileManager.default.contentsOfDirectory(atPath: "/dev") {
            let devices = contents.filter { $0.hasPrefix("cu.") && $0.lowercased().contains("usbmodem") }.sorted()
            if let first = devices.first { return "/dev/\(first)" }
        }
        return nil
    }

    private func configureSerial(_ fd: Int32) {
        var options = termios()
        tcgetattr(fd, &options)
        cfmakeraw(&options)
        cfsetispeed(&options, baudRate)
        cfsetospeed(&options, baudRate)

        // 8N1, no flow control
        options.c_cflag |= UInt(CS8 | CLOCAL | CREAD)
        options.c_cflag &= ~UInt(PARENB | CSTOPB | CRTSCTS)
        options.c_iflag &= ~UInt(IXON | IXOFF | IXANY)

        // Non-blocking reads
        options.c_cc.16 = 0  // VMIN
        options.c_cc.17 = 0  // VTIME

        tcsetattr(fd, TCSANOW, &options)
        tcflush(fd, TCIOFLUSH)

        // Assert DTR + RTS
        var bits: Int32 = 0x002 | 0x004 // TIOCM_DTR | TIOCM_RTS
        ioctl(fd, 0x8004746c, &bits)     // TIOCMBIS
    }

    // MARK: - KISS Helpers

    /// Write a KISS frame: FEND + type + SLIP-escaped payload + FEND
    private func writeKISS(_ fd: Int32, type: UInt8, payload: [UInt8]) {
        var frame: [UInt8] = [0xC0, type]
        for byte in payload {
            if byte == 0xC0 {
                frame.append(contentsOf: [0xDB, 0xDC])
            } else if byte == 0xDB {
                frame.append(contentsOf: [0xDB, 0xDD])
            } else {
                frame.append(byte)
            }
        }
        frame.append(0xC0)

        frame.withUnsafeBufferPointer { buf in
            _ = Darwin.write(fd, buf.baseAddress!, buf.count)
        }
    }

    /// Read all available bytes from fd (non-blocking)
    private func readAllAvailable(_ fd: Int32) -> [UInt8] {
        var result = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                result.append(contentsOf: buf[0..<n])
            } else {
                break
            }
        }
        return result
    }

    /// Extract complete KISS frames from raw byte stream.
    /// Returns array of frames, each starting with the type byte (FEND stripped, SLIP decoded).
    private func extractKISSFrames(from data: Data) -> [[UInt8]] {
        var frames = [[UInt8]]()
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            // Find FEND
            if bytes[i] == 0xC0 {
                i += 1
                // Skip consecutive FENDs
                while i < bytes.count && bytes[i] == 0xC0 { i += 1 }
                if i >= bytes.count { break }

                // Collect frame bytes until next FEND
                var frame = [UInt8]()
                var escaped = false
                while i < bytes.count && bytes[i] != 0xC0 {
                    if escaped {
                        if bytes[i] == 0xDC { frame.append(0xC0) }
                        else if bytes[i] == 0xDD { frame.append(0xDB) }
                        else { frame.append(bytes[i]) } // Malformed escape
                        escaped = false
                    } else if bytes[i] == 0xDB {
                        escaped = true
                    } else {
                        frame.append(bytes[i])
                    }
                    i += 1
                }
                if !frame.isEmpty {
                    frames.append(frame)
                }
            } else {
                i += 1
            }
        }
        return frames
    }

    // MARK: - AX.25 Helpers

    /// Build an AX.25 SABM frame (Set Asynchronous Balanced Mode, P=1)
    private func buildSABM(dest: String, destSSID: UInt8, src: String, srcSSID: UInt8) -> [UInt8] {
        var frame = [UInt8]()
        // Destination address (command bit set)
        frame.append(contentsOf: encodeAddress(dest, ssid: destSSID, isLast: false, commandResponse: true))
        // Source address (extension bit = 1 for last address)
        frame.append(contentsOf: encodeAddress(src, ssid: srcSSID, isLast: true, commandResponse: false))
        // Control: SABM = 0x2F with P=1 → 0x3F
        frame.append(0x3F)
        return frame
    }

    /// Build an AX.25 DISC frame (Disconnect, P=1)
    private func buildDISC(dest: String, destSSID: UInt8, src: String, srcSSID: UInt8) -> [UInt8] {
        var frame = [UInt8]()
        frame.append(contentsOf: encodeAddress(dest, ssid: destSSID, isLast: false, commandResponse: true))
        frame.append(contentsOf: encodeAddress(src, ssid: srcSSID, isLast: true, commandResponse: false))
        // Control: DISC = 0x43 with P=1 → 0x53
        frame.append(0x53)
        return frame
    }

    /// Encode a callsign + SSID into 7 bytes per AX.25 spec.
    /// Each character is shifted left 1 bit, padded with spaces to 6 chars.
    private func encodeAddress(_ call: String, ssid: UInt8, isLast: Bool, commandResponse: Bool) -> [UInt8] {
        var bytes = [UInt8]()
        let chars = Array(call.uppercased().utf8)
        for i in 0..<6 {
            bytes.append(i < chars.count ? (chars[i] << 1) : 0x40) // 0x40 = space << 1
        }
        // SSID byte: bit7=C/R, bit6:5=11 (reserved), bit4:1=SSID, bit0=extension
        var ssidByte = ((ssid & 0x0F) << 1) | 0x60
        if isLast { ssidByte |= 0x01 }
        if commandResponse { ssidByte |= 0x80 }
        bytes.append(ssidByte)
        return bytes
    }

    /// Decode source and destination addresses from raw AX.25 frame
    private func decodeAddresses(_ bytes: [UInt8]) -> (String, String) {
        guard bytes.count >= 14 else { return ("?", "?") }

        func decodeAddr(_ offset: Int) -> String {
            var call = ""
            for i in 0..<6 {
                let c = bytes[offset + i] >> 1
                if c != 0x20 { call.append(Character(UnicodeScalar(c))) }
            }
            let ssid = (bytes[offset + 6] >> 1) & 0x0F
            return "\(call)-\(ssid)"
        }

        return (decodeAddr(0), decodeAddr(7)) // dest, src
    }

    /// Describe an AX.25 control byte
    private func describeControlByte(_ ctl: UInt8) -> String {
        let masked = ctl & 0xEF // Strip P/F bit
        switch masked {
        case 0x2F: return "SABM"
        case 0x63: return "UA"
        case 0x0F: return "DM"
        case 0x43: return "DISC"
        case 0x87: return "FRMR"
        case 0x03: return "UI"
        default:
            if (ctl & 0x01) == 0 { return "I(\(ctl >> 5 & 7),\(ctl >> 1 & 7))" }
            if (ctl & 0x03) == 0x01 {
                let type = (ctl >> 2) & 0x03
                return ["RR", "RNR", "REJ", "SREJ"][Int(type)] + "(\(ctl >> 5 & 7))"
            }
            return "U(0x\(String(format: "%02X", ctl)))"
        }
    }

    private func hexDump(_ bytes: [UInt8]) -> String {
        bytes.prefix(128).map { String(format: "%02X", $0) }.joined(separator: " ") +
            (bytes.count > 128 ? "... (\(bytes.count) total)" : "")
    }

    private func hexDump(_ data: Data) -> String {
        hexDump([UInt8](data))
    }
}
