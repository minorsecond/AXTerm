#!/usr/bin/swift

import Foundation

// Configuration
let devicePath = "/dev/cu.usbmodem204B316146521"
let baudRate = 115200

func main() {
    print("🔵 [DIAG] Opening \(devicePath)...")
    let fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
    if fd < 0 {
        print("❌ Failed to open device")
        exit(1)
    }
    
    // Configure Port
    var options = termios()
    tcgetattr(fd, &options)
    cfmakeraw(&options)
    cfsetispeed(&options, speed_t(B115200))
    cfsetospeed(&options, speed_t(B115200))
    options.c_cflag &= ~UInt(CRTSCTS)
    tcsetattr(fd, TCSANOW, &options)
    
    // Send POLL_INPUT_LEVEL (0x06 0x04) repeatedly
    let pollFrame: [UInt8] = [0xC0, 0x06, 0x04, 0xC0]
    
    print("🔵 [DIAG] Polling Input Levels for 5 seconds...")
    
    let deadline = Date().addingTimeInterval(5)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
    var receivedData = Data()
    
    var vppSamples: [UInt16] = []
    
    // Poll loop
    while Date() < deadline {
        // Send Poll
        write(fd, pollFrame, pollFrame.count)
        
        // Read
        let bytesRead = read(fd, buffer, 4096)
        if bytesRead > 0 {
            let chunk = Data(bytes: buffer, count: bytesRead)
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            print("📥 RX: \(hex)")
        }
        
        Thread.sleep(forTimeInterval: 0.1)
    }
    
    close(fd)
}

main()
