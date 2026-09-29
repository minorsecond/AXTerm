#!/usr/bin/swift

import Foundation

// Configuration
let devicePath = "/dev/cu.usbmodem204B316146521"
let baudRate = 115200
let remoteCallsign = "K0EPI"
let localCallsign = "K0EPI"

// Constants
let FEND: UInt8 = 0xC0
let FESC: UInt8 = 0xDB
let TFEND: UInt8 = 0xDC
let TFESC: UInt8 = 0xDD

// KISS Commands
let CMD_DATA: UInt8 = 0x00
let CMD_HARDWARE: UInt8 = 0x06

// HW Commands
let HW_SET_INPUT_GAIN: UInt8 = 0x02
let HW_STREAM_INPUT: UInt8 = 29 // 0x1D

enum PacketType {
    case data(Data)
    case hardware(Data)
    case unknown(UInt8, Data)
}

class KISSStreamParser {
    private var buffer = Data()
    private var inFrame = false
    private var escape = false
    private var currentFrame = Data()
    
    var onPacket: ((PacketType) -> Void)?
    
    func feed(_ data: Data) {
        for byte in data {
            if byte == FEND {
                if inFrame && !currentFrame.isEmpty {
                    processFrame(currentFrame)
                }
                inFrame = true
                escape = false
                currentFrame.removeAll(keepingCapacity: true)
                continue
            }
            
            if !inFrame { continue }
            
            if escape {
                if byte == TFEND { currentFrame.append(FEND) }
                else if byte == TFESC { currentFrame.append(FESC) }
                else { currentFrame.append(byte) } // Error really
                escape = false
            } else if byte == FESC {
                escape = true
            } else {
                currentFrame.append(byte)
            }
        }
    }
    
    private func processFrame(_ frame: Data) {
        guard !frame.isEmpty else { return }
        let cmdByte = frame[0]
        let port = (cmdByte & 0xF0) >> 4
        let cmd = cmdByte & 0x0F
        let payload = frame.dropFirst()
        
        switch cmd {
        case CMD_DATA:
            onPacket?(.data(payload))
        case CMD_HARDWARE:
            onPacket?(.hardware(payload))
        default:
            onPacket?(.unknown(cmd, payload))
        }
    }
}

func main() {
    print("🔵 [TEST] Opening \(devicePath)...")
    let fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
    if fd < 0 {
        print("❌ Failed to open device: \(errno)")
        exit(1)
    }
    
    // Configure Serial (Raw Mode, 115200)
    var options = termios()
    tcgetattr(fd, &options)
    cfmakeraw(&options)
    cfsetispeed(&options, speed_t(B115200))
    cfsetospeed(&options, speed_t(B115200))
    
    // Disable Hardware Flow Control (CRTSCTS)
    options.c_cflag &= ~UInt(CRTSCTS)
    
    tcsetattr(fd, TCSANOW, &options)
    
    // Setup Parser
    let parser = KISSStreamParser()
    var uaReceived = false
    
    parser.onPacket = { packet in
        switch packet {
        case .data(let payload):
            // Check for UA
            if hasControlFrame(data: payload, type: 0x73) || hasControlFrame(data: payload, type: 0x63) {
                print("🎉 RX [DATA]: UA received!")
                uaReceived = true
            } else {
                print("   RX [DATA]: \(payload.count) bytes (Not UA)")
            }
        case .hardware(let payload):
            // Just log it briefly
            let hex = payload.prefix(4).map{ String(format:"%02X", $0) }.joined(separator:" ")
            print("   RX [HARDWARE]: \(hex)...")
        case .unknown(let cmd, _):
            print("   RX [CMD \(cmd)]")
        }
    }
    
    // 0. Cleanup: Stop Stream + Gain 0 (Matching Official App)
    print("🎛️ Configuring TNC (Stop Stream + Gain 0)...")
    
    let stopStream: [UInt8] = [FEND, CMD_HARDWARE, HW_STREAM_INPUT, 0x00, FEND]
    let setGain0: [UInt8] = [FEND, CMD_HARDWARE, HW_SET_INPUT_GAIN, 0x00, 0x00, FEND] // Gain 0
    
    // Give TNC time to wake up after port open
    Thread.sleep(forTimeInterval: 2.0)

    write(fd, stopStream, stopStream.count)
    Thread.sleep(forTimeInterval: 0.1)
    
    // Set Gain 0
    write(fd, setGain0, setGain0.count)
    Thread.sleep(forTimeInterval: 0.5)
    
    // Thread.sleep(forTimeInterval: 1.0) // Brief pause after open

    
    // 1. Send SABM
    print("🔵 Connecting (SABM)...")
    let sabmPayload = makeAX25SABM(dest: remoteCallsign, src: localCallsign)
    let sabmFrame = makeKISSFrame(command: CMD_DATA, payload: sabmPayload)
    
    // Retry Loop
    for i in 1...3 {
        print("   Attempt \(i)...")
        write(fd, sabmFrame, sabmFrame.count)
        
        let deadline = Date().addingTimeInterval(3.0)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
        
        while Date() < deadline && !uaReceived {
            let n = read(fd, buffer, 4096)
            if n > 0 {
                let chunk = Data(bytes: buffer, count: n)
                parser.feed(chunk)
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        buffer.deallocate()
        
        if uaReceived { break }
    }
    
    close(fd)
    
    if uaReceived {
        print("✅ SUCCESS: Connected!")
        exit(0)
    } else {
        print("❌ FAILURE: No UA received.")
        exit(1)
    }
}

// MARK: - Helpers

func makeKISSFrame(command: UInt8, payload: [UInt8]) -> [UInt8] {
    var frame: [UInt8] = [FEND, command]
    for byte in payload {
        if byte == FEND {
            frame.append(contentsOf: [FESC, TFEND])
        } else if byte == FESC {
            frame.append(contentsOf: [FESC, TFESC])
        } else {
            frame.append(byte)
        }
    }
    frame.append(FEND)
    return frame
}

func makeAX25SABM(dest: String, src: String) -> [UInt8] {
    var frame = [UInt8]()
    frame.append(contentsOf: encodeCallsign(dest, ssid: 7, last: false))
    frame.append(contentsOf: encodeCallsign(src, ssid: 6, last: true))
    frame.append(0x2F | 0x10) // SABM (0x2F) | P=1 (0x10) -> 0x3F
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

func hasControlFrame(data: Data, type: UInt8) -> Bool {
    // AX25: Dest(7)+Src(7)+Ctl(1)
    // Ctl is at index 14
    if data.count < 15 { return false }
    return data[14] == type
}

main()
