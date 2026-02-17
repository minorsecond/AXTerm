#!/usr/bin/swift

import Foundation

let devicePath = "/dev/cu.usbmodem204B316146521"
let baudRate = 115200

func main() {
    print("🔵 [LISTEN] Opening \(devicePath)...")
    let fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
    if fd < 0 {
        print("❌ Failed to open device")
        exit(1)
    }
    
    // Configure Serial Port
    var options = termios()
    tcgetattr(fd, &options)
    cfmakeraw(&options)
    let speed = speed_t(B115200)
    cfsetispeed(&options, speed)
    cfsetospeed(&options, speed)
    options.c_cflag &= ~UInt(CRTSCTS)
    tcsetattr(fd, TCSANOW, &options)
    
    print("🔵 [LISTEN] Listening for 30 seconds...")
    let deadline = Date().addingTimeInterval(30)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
    
    while Date() < deadline {
        let bytesRead = read(fd, buffer, 4096)
        if bytesRead > 0 {
            let chunk = Data(bytes: buffer, count: bytesRead)
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            print("📥 RX: \(hex)")
        } else {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    
    close(fd)
    print("✅ Done.")
}

main()
