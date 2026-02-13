//
//  KISSLinkSerial.swift
//  AXTerm
//
//  KISS transport over USB serial (POSIX).
//  Supports Mobilinkd TNC4 and other USB CDC devices.
//

import Foundation
import OSLog

// MARK: - Serial Configuration

/// Configuration for a serial port connection
struct SerialConfig: Equatable, Sendable {
    var devicePath: String
    var baudRate: Int
    var autoReconnect: Bool

    static let defaultBaudRate = 115200
    static let defaultAutoReconnect = true

    init(
        devicePath: String,
        baudRate: Int = Self.defaultBaudRate,
        autoReconnect: Bool = Self.defaultAutoReconnect
    ) {
        self.devicePath = devicePath
        self.baudRate = baudRate
        self.autoReconnect = autoReconnect
    }

    /// Map baud rate integer to POSIX speed constant
    var posixBaudRate: speed_t {
        switch baudRate {
        case 1200: return speed_t(B1200)
        case 2400: return speed_t(B2400)
        case 4800: return speed_t(B4800)
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default: return speed_t(B115200)
        }
    }

    /// Common baud rates for KISS TNCs
    static let commonBaudRates = [1200, 9600, 19200, 38400, 57600, 115200, 230400]
}

// MARK: - Serial Device Enumeration

/// Utility for discovering serial devices
enum SerialDeviceEnumerator {
    /// Patterns for likely KISS TNC devices
    private static let tncPatterns = ["cu.usbmodem", "cu.usbserial"]

    /// List serial devices matching TNC patterns
    static func likelyTNCDevices() -> [String] {
        allCUDevices().filter { path in
            tncPatterns.contains { path.contains($0) }
        }
    }

    /// List all /dev/cu.* devices
    static func allCUDevices() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: "/dev") else {
            return []
        }
        return items
            .filter { $0.hasPrefix("cu.") }
            .map { "/dev/\($0)" }
            .sorted()
    }
}

// MARK: - Serial Errors

nonisolated enum KISSSerialError: Error, LocalizedError {
    case deviceNotFound(String)
    case openFailed(String, Int32)
    case configurationFailed(String)
    case writeFailed(String)
    case notOpen

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let path):
            return "Serial device not found: \(path)"
        case .openFailed(let path, let errno):
            return "Failed to open \(path): \(String(cString: strerror(errno)))"
        case .configurationFailed(let reason):
            return "Serial configuration failed: \(reason)"
        case .writeFailed(let reason):
            return "Serial write failed: \(reason)"
        case .notOpen:
            return "Serial port not open"
        }
    }
}

// MARK: - KISSLinkSerial

/// KISS transport over a USB serial port using POSIX file I/O.
///
/// Uses DispatchSourceRead for non-blocking reads and feeds raw bytes
/// to the delegate (which runs the shared KISS deframer).
///
/// Features:
/// - Configurable baud rate (default 115200)
/// - Auto-reconnect when device disappears/reappears
/// - Idempotent open/close
/// - Thread-safe via dedicated serial queue
final class KISSLinkSerial: KISSLink, @unchecked Sendable {

    // MARK: - Configuration

    private(set) var config: SerialConfig

    // MARK: - KISSLink State

    private let lock = NSLock()
    private var _state: KISSLinkState = .disconnected

    var state: KISSLinkState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var endpointDescription: String {
        config.devicePath
    }

    weak var delegate: KISSLinkDelegate?

    // MARK: - Private State

    private var fileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let serialQueue = DispatchQueue(label: "com.axterm.kisslink.serial")
    private var reconnectTimer: DispatchSourceTimer?
    private var reconnectAttempt = 0
    private static let maxReconnectDelay: TimeInterval = 30
    private static let baseReconnectDelay: TimeInterval = 1
    private var originalTermios = termios()

    // MARK: - Stats

    private var _totalBytesIn = 0
    private var _totalBytesOut = 0

    var totalBytesIn: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalBytesIn
    }

    var totalBytesOut: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalBytesOut
    }

    // MARK: - Init

    init(config: SerialConfig) {
        self.config = config
    }

    deinit {
        closeInternal(reason: "deinit")
    }

    // MARK: - KISSLink Conformance

    func open() {
        serialQueue.async { [weak self] in
            self?.openInternal()
        }
    }

    func close() {
        serialQueue.async { [weak self] in
            self?.closeInternal(reason: "User initiated")
        }
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        serialQueue.async { [weak self] in
            guard let self else {
                completion(KISSSerialError.notOpen)
                return
            }

            let fd: Int32
            self.lock.lock()
            fd = self.fileDescriptor
            let current = self._state
            self.lock.unlock()

            guard current == .connected, fd >= 0 else {
                completion(KISSSerialError.notOpen)
                return
            }

            let result = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.write(fd, baseAddress, buffer.count)
            }

            if result < 0 {
                let err = errno
                let message = String(cString: strerror(err))
                KISSLinkLog.error(self.endpointDescription, message: "Write failed: \(message)")
                completion(KISSSerialError.writeFailed(message))
                // Device may have disconnected
                if err == ENXIO || err == EIO {
                    self.handleDeviceDisconnect()
                }
            } else {
                self.lock.lock()
                self._totalBytesOut += result
                self.lock.unlock()
                KISSLinkLog.bytesOut(self.endpointDescription, count: result)
                completion(nil)
            }
        }
    }

    /// Update configuration (e.g. when user changes settings).
    /// If currently connected, closes and reopens with new config.
    func updateConfig(_ newConfig: SerialConfig) {
        serialQueue.async { [weak self] in
            guard let self else { return }
            let wasConnected: Bool
            self.lock.lock()
            wasConnected = self._state == .connected
            self.lock.unlock()

            self.config = newConfig

            if wasConnected {
                self.closeInternal(reason: "Config changed")
                self.openInternal()
            }
        }
    }

    // MARK: - Private: Open

    private func openInternal() {
        lock.lock()
        let current = _state
        lock.unlock()

        guard current != .connecting && current != .connected else { return }

        setState(.connecting)
        KISSLinkLog.opened(endpointDescription)

        // Verify device exists
        guard FileManager.default.fileExists(atPath: config.devicePath) else {
            setState(.failed)
            notifyError("Device not found: \(config.devicePath)")
            scheduleReconnectIfEnabled()
            return
        }

        // Open the serial device
        let fd = Darwin.open(config.devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let err = errno
            setState(.failed)
            notifyError("Failed to open \(config.devicePath): \(String(cString: strerror(err)))")
            scheduleReconnectIfEnabled()
            return
        }

        // Configure the serial port
        do {
            try configurePort(fd: fd)
        } catch {
            Darwin.close(fd)
            setState(.failed)
            notifyError(error.localizedDescription)
            scheduleReconnectIfEnabled()
            return
        }

        // Clear O_NONBLOCK after configuration so reads block properly for DispatchSource
        var flags = fcntl(fd, F_GETFL)
        flags &= ~O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)

        lock.lock()
        fileDescriptor = fd
        _totalBytesIn = 0
        _totalBytesOut = 0
        lock.unlock()

        // Set up read source
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: serialQueue)

        source.setEventHandler { [weak self] in
            self?.handleReadEvent()
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let currentFd = self.fileDescriptor
            self.lock.unlock()
            if currentFd >= 0 {
                // Restore original termios before closing
                var origTermios = self.originalTermios
                tcsetattr(currentFd, TCSANOW, &origTermios)
                Darwin.close(currentFd)
                self.lock.lock()
                self.fileDescriptor = -1
                self.lock.unlock()
            }
        }

        lock.lock()
        readSource = source
        lock.unlock()

        source.resume()

        setState(.connected)
        reconnectAttempt = 0
        cancelReconnectTimer()
    }

    // MARK: - Private: Configure Port

    private func configurePort(fd: Int32) throws {
        // Save original settings for restore on close
        if tcgetattr(fd, &originalTermios) != 0 {
            throw KISSSerialError.configurationFailed("tcgetattr failed: \(String(cString: strerror(errno)))")
        }

        var options = termios()
        if tcgetattr(fd, &options) != 0 {
            throw KISSSerialError.configurationFailed("tcgetattr failed")
        }

        // Raw mode - no echo, no signals, no canonical processing
        cfmakeraw(&options)

        // Set baud rate
        let speed = config.posixBaudRate
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)

        // 8N1: 8 data bits, no parity, 1 stop bit
        options.c_cflag |= UInt(CS8)
        options.c_cflag &= ~UInt(PARENB)   // No parity
        options.c_cflag &= ~UInt(CSTOPB)   // 1 stop bit
        options.c_cflag &= ~UInt(CRTSCTS)  // No hardware flow control
        options.c_cflag |= UInt(CLOCAL | CREAD) // Enable receiver, ignore modem controls

        // Read at least 1 byte, with 100ms timeout between bytes
        // VMIN=16, VTIME=17 on macOS (Darwin)
        options.c_cc.16 = 1   // VMIN
        options.c_cc.17 = 1   // VTIME (1 = 100ms)

        if tcsetattr(fd, TCSANOW, &options) != 0 {
            throw KISSSerialError.configurationFailed("tcsetattr failed: \(String(cString: strerror(errno)))")
        }

        // Flush any stale data
        tcflush(fd, TCIOFLUSH)
    }

    // MARK: - Private: Read

    private func handleReadEvent() {
        lock.lock()
        let fd = fileDescriptor
        lock.unlock()

        guard fd >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(fd, &buffer, buffer.count)

        if bytesRead > 0 {
            let data = Data(buffer[0..<bytesRead])
            lock.lock()
            _totalBytesIn += bytesRead
            lock.unlock()
            KISSLinkLog.bytesIn(endpointDescription, count: bytesRead)
            Task { @MainActor [weak self] in
                self?.delegate?.linkDidReceive(data)
            }
        } else if bytesRead == 0 {
            // EOF - device disconnected
            handleDeviceDisconnect()
        } else {
            let err = errno
            if err != EAGAIN && err != EWOULDBLOCK {
                let message = String(cString: strerror(err))
                KISSLinkLog.error(endpointDescription, message: "Read error: \(message)")
                if err == ENXIO || err == EIO {
                    handleDeviceDisconnect()
                }
            }
        }
    }

    // MARK: - Private: Close

    private func closeInternal(reason: String) {
        cancelReconnectTimer()

        lock.lock()
        let source = readSource
        readSource = nil
        let fd = fileDescriptor
        lock.unlock()

        if let source = source {
            source.cancel() // Cancel handler will close fd and restore termios
        } else if fd >= 0 {
            // If no source was set up, close directly
            var origTermios = originalTermios
            tcsetattr(fd, TCSANOW, &origTermios)
            Darwin.close(fd)
            lock.lock()
            fileDescriptor = -1
            lock.unlock()
        }

        setState(.disconnected)
        KISSLinkLog.closed(endpointDescription, reason: reason)
    }

    // MARK: - Private: Device Disconnect & Reconnect

    private func handleDeviceDisconnect() {
        KISSLinkLog.error(endpointDescription, message: "Device disconnected")
        closeInternal(reason: "Device disconnected")
        notifyError("Device disconnected: \(config.devicePath)")
        scheduleReconnectIfEnabled()
    }

    private func scheduleReconnectIfEnabled() {
        guard config.autoReconnect else { return }

        reconnectAttempt += 1
        let delay = min(
            Self.baseReconnectDelay * pow(2, Double(reconnectAttempt - 1)),
            Self.maxReconnectDelay
        )

        KISSLinkLog.reconnect(endpointDescription, attempt: reconnectAttempt)

        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Check if device has reappeared
            if FileManager.default.fileExists(atPath: self.config.devicePath) {
                self.openInternal()
            } else {
                self.scheduleReconnectIfEnabled()
            }
        }

        lock.lock()
        reconnectTimer?.cancel()
        reconnectTimer = timer
        lock.unlock()

        timer.resume()
    }

    private func cancelReconnectTimer() {
        lock.lock()
        let timer = reconnectTimer
        reconnectTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    // MARK: - Private: State Helpers

    private func setState(_ newState: KISSLinkState) {
        let old: KISSLinkState
        lock.lock()
        old = _state
        _state = newState
        lock.unlock()

        if old != newState {
            KISSLinkLog.stateChange(endpointDescription, from: old, to: newState)
            Task { @MainActor [weak self] in
                self?.delegate?.linkDidChangeState(newState)
            }
        }
    }

    private func notifyError(_ message: String) {
        KISSLinkLog.error(endpointDescription, message: message)
        Task { @MainActor [weak self] in
            self?.delegate?.linkDidError(message)
        }
    }
}
