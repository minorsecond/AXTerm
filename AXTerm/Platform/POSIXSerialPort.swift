#if os(macOS)
import Darwin
import Foundation

/// A raw serial port: open, read by polling, write, modem lines.
///
/// Built for the radio's CI-V port (USB CDC-ACM), where two lessons from the
/// TNC serial link apply: kqueue read sources do not fire reliably for
/// unsolicited USB-CDC data, so reads are polled on a timer; and the modem
/// lines are **never touched on open** — a radio whose USB SEND follows RTS
/// or DTR would key the transmitter the moment the port opened.
nonisolated final class POSIXSerialPort: @unchecked Sendable {

    enum PortError: Error, Equatable, Sendable {
        case alreadyOpen(String)
        case openFailed(String, errno: Int32)
        case configureFailed(String, errno: Int32)
        case notOpen
        case writeFailed(errno: Int32)
    }

    let path: String
    let baudRate: Int
    /// Bytes as they arrive, on the port's queue.
    var onBytes: (@Sendable (Data) -> Void)?
    /// The device went away.
    var onDisconnect: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "com.axterm.serialport")
    private var descriptor: Int32 = -1
    private var poller: DispatchSourceTimer?
    private var originalTermios = termios()
    private var readBuffer = [UInt8](repeating: 0, count: 4096)

    /// One process, one open per path.
    private static let pathLock = NSLock()
    nonisolated(unsafe) private static var activePaths: Set<String> = []

    init(path: String, baudRate: Int = 115_200) {
        self.path = path
        self.baudRate = baudRate
    }

    deinit { close() }

    var isOpen: Bool { queue.sync { descriptor >= 0 } }

    func open() throws {
        try queue.sync {
            guard descriptor < 0 else { return }
            let claimed = Self.pathLock.withLock { Self.activePaths.insert(path).inserted }
            guard claimed else { throw PortError.alreadyOpen(path) }
            let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard fd >= 0 else {
                Self.pathLock.withLock { _ = Self.activePaths.remove(path) }
                throw PortError.openFailed(path, errno: errno)
            }
            do {
                try configure(fd)
            } catch {
                Darwin.close(fd)
                Self.pathLock.withLock { _ = Self.activePaths.remove(path) }
                throw error
            }
            descriptor = fd
            startPolling()
        }
    }

    func close() {
        queue.sync {
            poller?.cancel()
            poller = nil
            guard descriptor >= 0 else { return }
            tcsetattr(descriptor, TCSANOW, &originalTermios)
            Darwin.close(descriptor)
            descriptor = -1
            Self.pathLock.withLock { _ = Self.activePaths.remove(path) }
        }
    }

    func write(_ data: Data) throws {
        try queue.sync {
            guard descriptor >= 0 else { throw PortError.notOpen }
            var remaining = [UInt8](data)
            while !remaining.isEmpty {
                let n = remaining.withUnsafeBufferPointer { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                if n > 0 {
                    remaining.removeFirst(n)
                    continue
                }
                let code = errno
                if n < 0, code == EINTR { continue }
                if n < 0, code == EAGAIN || code == EWOULDBLOCK {
                    var pfd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 500)
                    continue
                }
                throw PortError.writeFailed(errno: code)
            }
        }
    }

    /// Raise or drop RTS/DTR; nil leaves a line alone.
    func setModemLines(dtr: Bool?, rts: Bool?) {
        queue.sync {
            guard descriptor >= 0 else { return }
            if let dtr {
                var bits: Int32 = TIOCM_DTR
                _ = ioctl(descriptor, dtr ? UInt(TIOCMBIS) : UInt(TIOCMBIC), &bits)
            }
            if let rts {
                var bits: Int32 = TIOCM_RTS
                _ = ioctl(descriptor, rts ? UInt(TIOCMBIS) : UInt(TIOCMBIC), &bits)
            }
        }
    }

    // MARK: - Internals (queue)

    private func configure(_ fd: Int32) throws {
        guard tcgetattr(fd, &originalTermios) == 0 else { throw PortError.configureFailed(path, errno: errno) }
        var options = originalTermios
        cfmakeraw(&options)
        let speed = Self.posixSpeed(baudRate)
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE)
        options.c_cflag |= tcflag_t(CS8)
        options.c_cflag &= ~tcflag_t(CRTSCTS)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        withUnsafeMutablePointer(to: &options.c_cc) { cc in
            cc.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { array in
                array[Int(VMIN)] = 0
                array[Int(VTIME)] = 0
            }
        }
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { throw PortError.configureFailed(path, errno: errno) }
        tcflush(fd, TCIOFLUSH)
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.pollOnce() }
        timer.resume()
        poller = timer
    }

    private func pollOnce() {
        guard descriptor >= 0 else { return }
        var collected = Data()
        while true {
            let n = readBuffer.withUnsafeMutableBufferPointer { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if n > 0 {
                collected.append(contentsOf: readBuffer[0..<n])
                if n < readBuffer.count { break }
                continue
            }
            if n == 0 { break }
            let code = errno
            if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { break }
            if code == ENXIO || code == EIO || code == ENODEV || code == EBADF {
                let message = "serial device \(path) went away (errno \(code))"
                poller?.cancel()
                poller = nil
                Darwin.close(descriptor)
                descriptor = -1
                Self.pathLock.withLock { _ = Self.activePaths.remove(path) }
                onDisconnect?(message)
                return
            }
            break
        }
        if !collected.isEmpty { onBytes?(collected) }
    }

    static func posixSpeed(_ baud: Int) -> speed_t {
        switch baud {
        case 1200: return speed_t(B1200)
        case 2400: return speed_t(B2400)
        case 4800: return speed_t(B4800)
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 230400: return speed_t(B230400)
        default: return speed_t(B115200)
        }
    }
}
#endif
