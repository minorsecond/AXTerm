import Foundation

setbuf(stdout, nil)

let args = CommandLine.arguments
let devicePath = args.count > 1 ? args[1] : "/dev/cu.TNC4Mobilinkd"

print("Opening \(devicePath) with O_NONBLOCK...")

let fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
if fd < 0 {
    print("Failed to open: \(errno) \(String(cString: strerror(errno)))")
    exit(1)
}
print("FD: \(fd)")

// Configure Serial Port
var options = termios()
tcgetattr(fd, &options)
cfmakeraw(&options)
cfsetispeed(&options, speed_t(B115200))
cfsetospeed(&options, speed_t(B115200))
options.c_cflag |= UInt(CS8 | CLOCAL | CREAD)
options.c_cflag &= ~UInt(CRTSCTS) 
tcsetattr(fd, TCSANOW, &options)

print("Sending KISS EXIT (C0 FF C0) and NEWLINE...")
let exitKISS: [UInt8] = [0xC0, 0xFF, 0xC0]
write(fd, exitKISS, 3)
write(fd, "\r\n", 2)

let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
defer { buffer.deallocate() }

var lastSendTime = Date()

print("Listening...")

while true {
    if Date().timeIntervalSince(lastSendTime) > 2.0 {
        print("Sending escape...")
        write(fd, "\r\n", 2)
        write(fd, exitKISS, 3)
        lastSendTime = Date()
    }

    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ret = poll(&pfd, 1, 100)
    
    if ret > 0 {
        if (pfd.revents & Int16(POLLIN)) != 0 {
            let bytesRead = read(fd, buffer, 4096)
            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                if let str = String(data: data, encoding: .utf8) {
                    print("RX String: \(str)")
                }
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("RX Hex: \(hex)")
            } else {
                 print("EOF")
                 exit(0)
            }
        }
    }
}
