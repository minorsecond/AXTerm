#!/usr/bin/swift

import Foundation

// Configuration
let devicePath = "/dev/cu.usbmodem204B316146521"
let baudRate = 115200
let remoteCallsign = "K0EPI-7"
let localCallsign = "K0EPI-6"

func main() {
    print("🔵 [TEST] Opening \(devicePath) at \(baudRate)...")
    
    let fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
    if fd < 0 {
        print("❌ Failed to open device: \(errno) \(String(cString: strerror(errno)))")
        exit(1)
    }
    
    // Configure Serial Port
    var options = termios()
    tcgetattr(fd, &options)
    cfmakeraw(&options)
    let speed = speed_t(B115200)
    cfsetispeed(&options, speed)
    cfsetospeed(&options, speed)
    
    // Disable flow control
    options.c_cflag &= ~UInt(CRTSCTS)
    options.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
    options.c_cflag |= UInt(CLOCAL | CREAD)
    
    tcsetattr(fd, TCSANOW, &options)
    
    // Assert DTR/RTS
    var bits: Int32 = 0x002 | 0x004
    ioctl(fd, 0x8004746c, &bits)
    
    print("✅ Port configured.")
    
    print("\n🔄 Verification Attempt: Drain + Reset + Connection (Gain 4)")

    // -1. Aggressive Drain (5s)
    print("   Draining existing telemetry (5s)...")
    let preDrainDeadline = Date().addingTimeInterval(5)
    let preDrainBuf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
    while Date() < preDrainDeadline {
        if read(fd, preDrainBuf, 4096) > 0 {
            // dumping
        } else {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    preDrainBuf.deallocate()
    
    // 0. Send Reset
    let resetFrame: [UInt8] = [0xC0, 0x06, 0x0B, 0xC0]
    print("   Sending Reset...")
    write(fd, resetFrame, resetFrame.count)
    Thread.sleep(forTimeInterval: 2.0) // Wait for reboot

    // 1. Configure TNC (Gain 4)
    let gainFrame: [UInt8] = [0xC0, 0x06, 0x02, 0x00, 0x04, 0xC0]
    
    print("   Sending Input Gain 4...")
    write(fd, gainFrame, gainFrame.count)
    Thread.sleep(forTimeInterval: 0.5)
    
    // Drain buffer
    print("   Draining buffer...")
    let drainBuf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
    while read(fd, drainBuf, 4096) > 0 { }
    drainBuf.deallocate()
    
    // 2. Send SABM (retry a few times)
    print("   🔵 Sending SABM (3 attempts)...")
    let payload = makeAX25SABM(dest: remoteCallsign, src: localCallsign)
    let frame = makeKISSFrame(command: 0x00, payload: payload) // Command 0 = Data
    
    // Retry loop for SABM
    for i in 1...3 {
        print("   Attempt \(i)...")
        write(fd, frame, frame.count)
        
        // Short listen (3s)
        let deadline = Date().addingTimeInterval(3)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
        var receivedData = Data()
        var success = false
        
        while Date() < deadline {
            let bytesRead = read(fd, buffer, 4096)
            if bytesRead > 0 {
                let chunk = Data(bytes: buffer, count: bytesRead)
                receivedData.append(chunk)
                print("   📥 RX Chunk: \(chunk.map { String(format: "%02X", $0) }.joined(separator: " "))")
                
                if hasUA(in: receivedData) {
                    print("🎉 SUCCESS: Received UA response!")
                    success = true
                    break
                }
            } else {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        buffer.deallocate()
        
        if success {
            close(fd)
            exit(0)
        }
    }
    
    print("\n❌ FAILURE: Connection attempt failed after 3 retries.")
    close(fd)
    exit(1)
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

func hasUA(in data: Data) -> Bool {
    let frames = data.split(separator: 0xC0)
    for frame in frames {
        if frame.count < 10 { continue }
        if frame.first != 0x00 { continue }
        
        let ax25 = frame.dropFirst()
        if ax25.count < 15 { continue }
        
        let control = ax25[ax25.startIndex + 14]
        if control == 0x73 || control == 0x63 {
            return true
        }
    }
    return false
}

main()
