import Foundation

setbuf(stdout, nil) // Unbuffer stdout

let devicePath = "/dev/cu.usbmodem204B316146521"
let baudRate = 115200

print("Opening \(devicePath)...")

guard let fileHandle = FileHandle(forUpdatingAtPath: devicePath) else {
    fputs("Failed to open \(devicePath)\n", stderr)
    exit(1)
}

let fd = fileHandle.fileDescriptor
print("FD: \(fd)")

// Configure Serial Port
var options = termios()
if tcgetattr(fd, &options) != 0 {
    print("tcgetattr failed")
    exit(1)
}

cfmakeraw(&options)
cfsetispeed(&options, speed_t(B115200))
cfsetospeed(&options, speed_t(B115200))

options.c_cflag |= UInt(CS8)     // 8 data bits
options.c_cflag &= ~UInt(PARENB) // No parity
options.c_cflag &= ~UInt(CSTOPB) // 1 stop bit

// Disable Flow Control
options.c_cflag &= ~UInt(CRTSCTS)
options.c_iflag &= ~UInt(IXON | IXOFF | IXANY)

options.c_cflag |= UInt(CLOCAL | CREAD)
options.c_cc.16 = 0 // VMIN
options.c_cc.17 = 0 // VTIME

if tcsetattr(fd, TCSANOW, &options) != 0 {
    print("tcsetattr failed")
}

print("Port configured. ASSERTING DTR/RTS...")
var bits: Int32 = 0x002 | 0x004 // TIOCM_DTR | TIOCM_RTS
if ioctl(fd, 0x8004746c, &bits) == -1 {
     print("Failed to assert DTR/RTS")
}

// Send Battery Poll
let batteryPoll: [UInt8] = [0xC0, 0x06, 0x06, 0xC0]
let data = Data(batteryPoll)

print("Sending Battery Poll looped...")

let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
defer { buffer.deallocate() }

var lastSendTime = Date()

while true {
    // Send poll every 2 seconds
    if Date().timeIntervalSince(lastSendTime) > 2.0 {
        print("Sending poll...")
        fileHandle.write(data)
        lastSendTime = Date()
    }

    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ret = poll(&pfd, 1, 100) // 100ms timeout
    
    if ret > 0 {
        if (pfd.revents & Int16(POLLIN)) != 0 {
            let bytesRead = read(fd, buffer, 4096)
            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("RX \(bytesRead) bytes: \(hex)")
            } else if bytesRead == 0 {
                print("EOF detected.")
                exit(0)
            } else {
                print("Read error: \(errno)")
            }
        }
    } else if ret < 0 {
        print("Poll error: \(errno)")
        exit(1)
    }
    // Timeout (ret == 0) -> Loop
}
