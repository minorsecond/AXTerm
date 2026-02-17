#!/usr/bin/swift

import Foundation

let devicePath = "/dev/cu.usbmodem204B316146521"

// Constants
let FEND: UInt8 = 0xC0
let CMD_HARDWARE: UInt8 = 0x06
let GET_BATTERY_LEVEL: UInt8 = 0x06

func main() {
    print("🔋 Checking TNC Battery Level...")
    let fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else {
        print("❌ Failed to open port: \(String(cString: strerror(errno)))")
        exit(1)
    }

    // Configure Port (Briefly)
    var options = termios()
    tcgetattr(fd, &options)
    cfmakeraw(&options)
    cfsetispeed(&options, speed_t(B115200))
    cfsetospeed(&options, speed_t(B115200))
    tcsetattr(fd, TCSANOW, &options)

    // Send Battery Poll
    let pollFrame: [UInt8] = [FEND, CMD_HARDWARE, GET_BATTERY_LEVEL, FEND]
    write(fd, pollFrame, pollFrame.count)

    // Listen for response
    var buffer = [UInt8](repeating: 0, count: 1024)
    let start = Date()
    while Date().timeIntervalSince(start) < 2.0 {
        let n = read(fd, &buffer, 1024)
        if n > 0 {
            let data = Array(buffer[0..<n])
            // Look for battery response: C0 06 06 HIGH LOW C0
            // Simple parser:
            if data.count >= 5, data[0] == FEND, data[1] == CMD_HARDWARE, data[2] == GET_BATTERY_LEVEL {
                let high = Int(data[3])
                let low = Int(data[4])
                let mv = (high << 8) + low
                print("✅ Battery Voltage: \(mv) mV")
                exit(0)
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    print("❌ No battery response received.")
}

main()
