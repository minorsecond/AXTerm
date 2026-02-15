import Foundation

let devicePath = "/dev/cu.usbmodem204B316146521"
let baudRate = 115200

print("Opening \(devicePath)...")

guard let fileHandle = FileHandle(forUpdatingAtPath: devicePath) else {
    print("Failed to open \(devicePath)")
    exit(1)
}

let fd = fileHandle.fileDescriptor

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

print("Sending Battery Poll...")
fileHandle.write(Data(batteryPoll))

print("Listening for data... (Press Ctrl+C to stop)")

// Read Loop - using non-blocking read manually via polling availableData which blocks? 
// availableData returns empty if EOF.
// If TNC is alive, it should respond instantly.

let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    print("Re-sending poll...")
    fileHandle.write(Data(batteryPoll))
}

let runLoop = RunLoop.current
// We need to read on a separate thread or use DispatchSource if we want to use RunLoop for timer.
// But valid swift script can just loop.

// Improved Read Loop
let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
defer { buffer.deallocate() }

while true {
    // Poll?
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ret = poll(&pfd, 1, 1000) // 1 second timeout
    
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
    } else if ret == 0 {
        // Timeout
        // print(".")
        // Re-send poll every few seconds
        print("Timeout, sending poll again...")
        fileHandle.write(Data(batteryPoll))
    } else {
        print("Poll error: \(errno)")
        exit(1)
    }
}
