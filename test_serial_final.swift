import Foundation

setbuf(stdout, nil)

let args = CommandLine.arguments
let devicePath = args.count > 1 ? args[1] : "/dev/cu.usbmodem204B316146521"
let baudRate = args.count > 2 ? Int(args[2]) : 115200

print("Opening \(devicePath) at \(baudRate) baud with O_NONBLOCK...")

let fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
if fd < 0 {
    print("Failed to open: \(errno) \(String(cString: strerror(errno)))")
    exit(1)
}
print("FD: \(fd)")

// Configure Serial Port
var options = termios()
if tcgetattr(fd, &options) != 0 {
    print("tcgetattr failed")
}

cfmakeraw(&options)
let speed: speed_t
switch baudRate {
case 1200: speed = speed_t(B1200)
case 9600: speed = speed_t(B9600)
case 19200: speed = speed_t(B19200)
case 38400: speed = speed_t(B38400)
case 57600: speed = speed_t(B57600)
case 230400: speed = speed_t(B230400)
default: speed = speed_t(B115200) // Default 115200
}

cfsetispeed(&options, speed)
cfsetospeed(&options, speed)

options.c_cflag |= UInt(CS8)
options.c_cflag &= ~UInt(PARENB)
options.c_cflag &= ~UInt(CSTOPB)
options.c_cflag &= ~UInt(CRTSCTS)
options.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
options.c_cflag |= UInt(CLOCAL | CREAD)
options.c_cc.16 = 0 // VMIN
options.c_cc.17 = 0 // VTIME

if tcsetattr(fd, TCSANOW, &options) != 0 {
    print("tcsetattr failed")
}

print("Port configured. ASSERTING DTR/RTS...")
var bits: Int32 = 0x002 | 0x004
if ioctl(fd, 0x8004746c, &bits) == -1 {
     print("Failed to assert DTR/RTS")
}

print("Sending BREAK...")
tcsendbreak(fd, 0)

// Send Battery Poll
let batteryPoll: [UInt8] = [0xC0, 0x06, 0x06, 0xC0]

print("Sending Battery Poll looped...")

let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
defer { buffer.deallocate() }

var lastSendTime = Date()

while true {
    // Send poll every 2 seconds
    if Date().timeIntervalSince(lastSendTime) > 2.0 {
        print("Sending poll...")
        let written = write(fd, batteryPoll, batteryPoll.count)
        if written < 0 {
             print("Write error: \(errno)")
        } else {
             print("Written \(written) bytes")
        }
        lastSendTime = Date()
    }

    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ret = poll(&pfd, 1, 100)
    
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
                if errno != EAGAIN {
                    print("Read error: \(errno)")
                }
            }
        }
        if (pfd.revents & Int16(POLLHUP)) != 0 {
            print("POLLHUP detected")
            exit(0)
        }
    } else if ret < 0 {
        print("Poll error: \(errno)")
        exit(1)
    }
}
