#if AXTERM_RF_TESTS
//
//  RealHardwareTNCTests.swift
//  AXTermTests
//
//  Integration tests that run against REAL TNC HARDWARE.
//  Requires AXTERM_RF_TESTS build flag and /tmp/axterm_rf_tests_enabled sentinel.
//

import XCTest
@testable import AXTerm

/// Integration tests that run against REAL TNC HARDWARE.
/// WARNING: Requires a TNC connected at the specified path.
final class RealHardwareTNCTests: XCTestCase {

    let devicePath = "/dev/cu.usbmodem204B316146521"
    let baudRate = 115200
    let remoteCallsign = "K0EPI-7"
    let localCallsign = "K0EPI-6"

    var fileDescriptor: Int32 = -1

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.fileExists(atPath: "/tmp/axterm_rf_tests_enabled") else {
            throw XCTSkip("RF tests disabled — use run_rf_tests.sh to enable")
        }
        fileDescriptor = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fileDescriptor < 0 {
            throw XCTSkip("Device not available at \(devicePath)")
        }

        var options = termios()
        tcgetattr(fileDescriptor, &options)
        cfmakeraw(&options)
        let speed = speed_t(B115200)
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)

        options.c_cflag |= UInt(CS8 | CLOCAL | CREAD)
        options.c_cflag &= ~UInt(PARENB | CSTOPB | CRTSCTS)
        options.c_iflag &= ~UInt(IXON | IXOFF | IXANY)

        // Non-blocking reads
        options.c_cc.16 = 0  // VMIN
        options.c_cc.17 = 0  // VTIME

        tcsetattr(fileDescriptor, TCSANOW, &options)
        tcflush(fileDescriptor, TCIOFLUSH)

        // Assert DTR/RTS
        var bits: Int32 = 0x002 | 0x004
        ioctl(fileDescriptor, 0x8004746c, &bits)
    }

    override func tearDown() {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        super.tearDown()
    }

    /// Test: send RESET to start demodulator, then SABM, wait for UA.
    func testConnectToK0EPI7() throws {
        NSLog("[REAL] Sending RESET to start demodulator...")

        // 1. Send RESET — starts demodulator using EEPROM config
        writeKISS(fileDescriptor, type: 0x06, payload: [0x0B])
        Thread.sleep(forTimeInterval: 3.0)

        // Drain any telemetry responses from RESET
        _ = readAllAvailable(fileDescriptor)

        // 2. Construct and send SABM
        let sabmFrame = makeKISSFrame(
            command: 0x00,
            payload: makeAX25SABM(dest: remoteCallsign, src: localCallsign)
        )

        let written = Darwin.write(fileDescriptor, sabmFrame, sabmFrame.count)
        XCTAssertEqual(written, sabmFrame.count, "Failed to write full frame")
        NSLog("[REAL] Sent SABM (%d bytes). Waiting for UA...", written)

        // 3. Wait for UA (up to 20s — allows for retransmits over RF)
        var allRX = Data()
        var gotUA = false
        let deadline = Date().addingTimeInterval(20)

        while Date() < deadline {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(fileDescriptor, &buf, buf.count)
            if n > 0 {
                let chunk = Data(buf[0..<n])
                allRX.append(chunk)
                NSLog("[REAL] RX %d bytes: %@", n, chunk.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " "))

                if isValidUA(data: allRX) {
                    NSLog("[REAL] *** GOT UA! ***")
                    gotUA = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        if !gotUA {
            NSLog("[REAL] Total RX: %d bytes", allRX.count)
        }
        XCTAssertTrue(gotUA, "Should receive UA from K0EPI-7")
    }

    // MARK: - Helpers

    private func writeKISS(_ fd: Int32, type: UInt8, payload: [UInt8]) {
        var frame: [UInt8] = [0xC0, type]
        for byte in payload {
            if byte == 0xC0 { frame.append(contentsOf: [0xDB, 0xDC]) }
            else if byte == 0xDB { frame.append(contentsOf: [0xDB, 0xDD]) }
            else { frame.append(byte) }
        }
        frame.append(0xC0)
        frame.withUnsafeBufferPointer { buf in
            _ = Darwin.write(fd, buf.baseAddress!, buf.count)
        }
    }

    private func readAllAvailable(_ fd: Int32) -> [UInt8] {
        var result = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 { result.append(contentsOf: buf[0..<n]) } else { break }
        }
        return result
    }

    func makeKISSFrame(command: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0xC0, command]
        for byte in payload {
            if byte == 0xC0 { frame.append(contentsOf: [0xDB, 0xDC]) }
            else if byte == 0xDB { frame.append(contentsOf: [0xDB, 0xDD]) }
            else { frame.append(byte) }
        }
        frame.append(0xC0)
        return frame
    }

    func makeAX25SABM(dest: String, src: String) -> [UInt8] {
        var frame = [UInt8]()
        frame.append(contentsOf: encodeCallsign(dest, ssid: 7, last: false))
        frame.append(contentsOf: encodeCallsign(src, ssid: 6, last: true))
        frame.append(0x3F) // SABM | P=1
        return frame
    }

    func encodeCallsign(_ call: String, ssid: Int, last: Bool) -> [UInt8] {
        var bytes = [UInt8]()
        for char in call.uppercased().utf8 {
            bytes.append(char << 1)
        }
        while bytes.count < 6 { bytes.append(0x40) }
        var ssidByte = UInt8((ssid & 0x0F) << 1) | 0x60
        if last { ssidByte |= 0x01 }
        bytes.append(ssidByte)
        return bytes
    }

    func isValidUA(data: Data) -> Bool {
        let split = data.split(separator: 0xC0)
        for frame in split {
            if frame.count < 15 { continue }
            if frame.first != 0x00 { continue }
            let ctlIndex = 1 + 14
            if frame.count > ctlIndex {
                let ctl = frame[ctlIndex]
                if (ctl & 0xEF) == 0x63 { return true }
            }
        }
        return false
    }
}
#endif
