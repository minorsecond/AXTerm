import Foundation

setbuf(stdout, nil)

let args = CommandLine.arguments
let devicePath = args.count > 1 ? args[1] : "/dev/cu.usbmodem204B316146521"
// let baudRate = args.count > 2 ? Int(args[2]) : 115200

print("Opening \(devicePath) at 115200 baud with O_NONBLOCK...")

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
let speed = speed_t(B115200)
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

// Helper to shift callsign
func shift(_ call: String, ssid: Int, last: Bool = false) -> [UInt8] {
    var bytes = [UInt8]()
    let upper = call.uppercased()
    for char in upper.utf8 {
        bytes.append(char << 1)
    }
    while bytes.count < 6 {
        bytes.append(0x20 << 1) // Space
    }
    var ssidByte = UInt8((ssid & 0x0F) << 1) | 0x60 // 0x60 = Reserved bits + C/R?
    if last {
        ssidByte |= 0x01 // Set last address bit
    }
    bytes.append(ssidByte)
    return bytes
}

// Construct SABM Frame
// Dest: K0EPI-7
// Source: K0EPI-6
// Control: SABM (0x2F) | P (0x10) => 0x3F

var packet = [UInt8]()
packet.append(0xC0) // FEND
packet.append(0x00) // Port 0
packet.append(contentsOf: shift("K0EPI", ssid: 7)) // Dest
packet.append(contentsOf: shift("K0EPI", ssid: 6, last: true)) // Source (Last)
packet.append(0x3F) // SABM + P
packet.append(0xC0) // FEND

print("Sending SABM to K0EPI-7 from K0EPI-6...")
let data = Data(packet)
let written = write(fd, packet, packet.count)
print("Written \(written) bytes")

// Also send KISS Init in case TNC needs it
let initFrames: [[UInt8]] = [
    [0xC0, 0x05, 0x01, 0xC0], // Duplex=1
    [0xC0, 0x02, 0xFF, 0xC0], // Persistence=255
    [0xC0, 0x03, 0x00, 0xC0], // SlotTime=0
    [0xC0, 0x01, 30, 0xC0],   // TXDelay=30
    [0xC0, 0x06, 0x01, 0x00, 0x80, 0xC0], // Volume TX (128)
    [0xC0, 0x06, 0x02, 0x00, 0x04, 0xC0]  // Volume RX (4)
]
print("Sending Init...")
for frame in initFrames {
    write(fd, frame, frame.count)
    Thread.sleep(forTimeInterval: 0.1)
}

print("Listening for response...")

let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
defer { buffer.deallocate() }

while true {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ret = poll(&pfd, 1, 1000)
    
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
            }
        }
    } else if ret == 0 {
        // Timeout
        // Resend SABM every 5 seconds
        // print(".")
    }
}
