//
//  RealHardwareTNCTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2/14/26.
//

import XCTest
@testable import AXTerm

/// Integration tests that run against REAL TNC HARDWARE.
/// Intended to reproduce the "TX works, RX fails" issue.
///
/// WARNING: Requires a TNC connected at the specified path.
final class RealHardwareTNCTests: XCTestCase {
    
    // Configure your device path here
    let devicePath = "/dev/cu.usbmodem204B316146521"
    let baudRate = 115200
    
    // Remote station to connect to
    let remoteCallsign = "K0EPI-7"
    let localCallsign = "K0EPI-6"
    
    var fileDescriptor: Int32 = -1
    
    override func setUp() {
        super.setUp()
        // Open the serial port directly to bypass AXTerm's stack for raw verification
        fileDescriptor = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fileDescriptor < 0 {
            print("⚠️ Skipped: Could not open \(devicePath). Is the device connected and free?")
            throw XCTSkip("Device not available")
        }
        
        var options = termios()
        tcgetattr(fileDescriptor, &options)
        cfmakeraw(&options)
        let speed = speed_t(B115200)
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)
        
        // Disable flow control
        options.c_cflag &= ~UInt(CRTSCTS)
        options.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
        
        tcsetattr(fileDescriptor, TCSANOW, &options)
        
        // Assert DTR/RTS
        var bits: Int32 = 0x002 | 0x004
        ioctl(fileDescriptor, 0x8004746c, &bits)
    }
    
    override func tearDown() {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        super.tearDown()
    }
    
    /// Test that attempts to connect to K0EPI-7 and waits for a UA response.
    /// Fails if no UA is received within timeout.
    func testConnectToK0EPI7() throws {
        print("🔵 sending SABM to \(remoteCallsign) from \(localCallsign)")
        
        // 1. Construct SABM Frame
        let sabmFrame = makeKISSFrame(
            command: 0x00, // Data
            payload: makeAX25SABM(dest: remoteCallsign, src: localCallsign)
        )
        
        // 2. Send Frame
        let written = write(fileDescriptor, sabmFrame, sabmFrame.count)
        XCTAssertEqual(written, sabmFrame.count, "Failed to write full frame")
        
        print("✅ Sent \(written) bytes. Waiting for response...")
        
        // 3. Listen for Response (Timeout 10s)
        let expectation = XCTestExpectation(description: "Receive UA response")
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 1)
        defer { buffer.deallocate() }
        
        let deadline = Date().addingTimeInterval(10)
        var receivedData = Data()
        
        while Date() < deadline {
            let bytesRead = read(fileDescriptor, buffer, 1024)
            if bytesRead > 0 {
                let chunk = Data(bytes: buffer, count: bytesRead)
                receivedData.append(chunk)
                
                print("📥 RX Chunk: \(chunk.map { String(format: "%02X", $0) }.joined(separator: " "))")
                
                // Parse for UA frame
                if isValidUA(data: receivedData, src: remoteCallsign, dest: localCallsign) {
                    print("🎉 Received VALID UA from \(remoteCallsign)!")
                    expectation.fulfill()
                    break
                }
            }
            
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        wait(for: [expectation], timeout: 10.0)
    }
    
    // MARK: - Helpers
    
    func makeKISSFrame(command: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0xC0, command] // FEND, Cmd
        
        // Escape FEND/FESC in payload
        for byte in payload {
            if byte == 0xC0 {
                frame.append(contentsOf: [0xDB, 0xDC])
            } else if byte == 0xDB {
                frame.append(contentsOf: [0xDB, 0xDD])
            } else {
                frame.append(byte)
            }
        }
        
        frame.append(0xC0) // FEND
        return frame
    }
    
    func makeAX25SABM(dest: String, src: String) -> [UInt8] {
        var frame = [UInt8]()
        frame.append(contentsOf: encodeCallsign(dest, ssid: 7, last: false))
        frame.append(contentsOf: encodeCallsign(src, ssid: 6, last: true))
        frame.append(0x3F) // SABM (0x2F) | P (0x10)
        return frame
    }
    
    func encodeCallsign(_ call: String, ssid: Int, last: Bool) -> [UInt8] {
        var bytes = [UInt8]()
        let upper = call.uppercased()
        for char in upper.utf8 {
            bytes.append(char << 1)
        }
        while bytes.count < 6 {
            bytes.append(0x40) // Space << 1
        }
        
        var ssidByte = UInt8((ssid & 0x0F) << 1) | 0x60
        if last { ssidByte |= 0x01 }
        bytes.append(ssidByte)
        return bytes
    }
    
    func isValidUA(data: Data, src: String, dest: String) -> Bool {
        // Simple search for UA byte sequence in decoded KISS data
        // For robustness, full breakdown needed, but searching for the control byte pattern is a good heuristic
        // We look for: Dest(Latched) + Src + UA(0x73 or 0x63)
        // UA response to SABM(P=1) is UA(F=1) => 0x63 + 0x10 => 0x73. Or just 0x63(UA) | 0x10(F).
        // 0x73 = 0111 0011 (UA + F)
        // 0x63 = 0110 0011 (UA)
        
        // Scan for FEND ... FEND
        let split = data.split(separator: 0xC0)
        for frame in split {
            if frame.count < 15 { continue } // Min size for U frame
            
            // Check port 0
            if frame.first != 0x00 { continue }
            
            // Should decode AX.25 addresses to be sure, but let's check Control byte
            let ctlIndex = 1 + 14 // 1 (Cmd) + 7 (Dest) + 7 (Src)
            if frame.count > ctlIndex {
                let ctl = frame[ctlIndex]
                // UA is 0x63 (01100011)
                // With F bit: 0x73
                if (ctl & 0xEF) == 0x63 {
                    return true
                }
            }
        }
        return false
    }
}
