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
    var mobilinkdConfig: MobilinkdConfig?

    static let defaultBaudRate = 115200
    static let defaultAutoReconnect = true

    init(
        devicePath: String,
        baudRate: Int = Self.defaultBaudRate,
        autoReconnect: Bool = Self.defaultAutoReconnect,
        mobilinkdConfig: MobilinkdConfig? = nil
    ) {
        self.devicePath = devicePath
        self.baudRate = baudRate
        self.autoReconnect = autoReconnect
        self.mobilinkdConfig = mobilinkdConfig
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



// MARK: - Serial Errors

nonisolated enum KISSSerialError: Error, LocalizedError {
    case deviceNotFound(String)
    case openFailed(String, Int32)
    case configurationFailed(String)
    case writeFailed(String)
    case notOpen
    case openTimeout(String)

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
        case .openTimeout(let path):
            return "Timed out opening \(path) (Bluetooth RFCOMM connection failed)"
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
    
    // Unique ID to track instance lifetime
    private let id = UUID()

    var state: KISSLinkState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }
    
    // MARK: - Static Guard (Cross-Instance Single Flight)
    // Tracks currently open or opening device paths to prevent concurrent access
    private static let pathLock = NSLock()
    private static var activePaths: Set<String> = []

    var endpointDescription: String {
        config.devicePath
    }

    weak var delegate: KISSLinkDelegate?

    // MARK: - Private State

    private var fileDescriptor: Int32 = -1
    private var readPollTimer: DispatchSourceTimer?
    private let serialQueue = DispatchQueue(label: "com.axterm.kisslink.serial", qos: .userInitiated)
    private var reconnectTimer: DispatchSourceTimer?
    private var batteryPollTimer: DispatchSourceTimer?
    private var kissInitWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private static let maxReconnectDelay: TimeInterval = 15 // Cap at 15s per requirements
    private static let baseReconnectDelay: TimeInterval = 1
    private static let btOpenTimeout: TimeInterval = 10 // Timeout for BT serial open()
    private var originalTermios = termios()
    private var isBluetoothSerial = false

    // MARK: - Stats

    private var _totalBytesIn = 0
    private var _totalBytesOut = 0

    var totalBytesIn: Int { lock.lock(); defer { lock.unlock() }; return _totalBytesIn }
    var totalBytesOut: Int { lock.lock(); defer { lock.unlock() }; return _totalBytesOut }

    // MARK: - Init

    init(config: SerialConfig) {
        self.config = config
        KISSLinkLog.info(config.devicePath, message: "Link init [\(_shortID)]")
    }

    deinit {
        let reason = "deinit [\(_shortID)]"
        closeInternal(reason: reason)
        KISSLinkLog.info(config.devicePath, message: "Link deinit [\(_shortID)]")
    }
    
    private var _shortID: String {
        String(id.uuidString.prefix(6))
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
            
            // Log hex dump of outbound frame for debugging
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            KISSLinkLog.info(self.endpointDescription, message: "Writing \(data.count) bytes: \(hex)")

            // WRITE LOOP: Ensure full frame is written
            var bytesWritten = 0
            let totalBytes = data.count
            
            let result = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                
                while bytesWritten < totalBytes {
                    let ptr = baseAddress.advanced(by: bytesWritten)
                    let remaining = totalBytes - bytesWritten
                    let count = Darwin.write(fd, ptr, remaining)
                    
                    if count < 0 {
                        let err = errno
                        if err == EINTR { continue }
                        if err == EAGAIN || err == EWOULDBLOCK {
                            // FD is non-blocking; output buffer momentarily full.
                            // Use poll() to wait for writability (up to 500ms).
                            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                            let pollResult = poll(&pfd, 1, 500)
                            if pollResult > 0 { continue } // Writable now, retry
                            KISSLinkLog.error(self.endpointDescription, message: "Write poll timeout or error")
                            return -1
                        }
                        return -1 // Real error
                    }
                    bytesWritten += count
                }
                return bytesWritten
            }

            if result < 0 {
                let err = errno
                let message = String(cString: strerror(err))
                KISSLinkLog.error(self.endpointDescription, message: "Write failed (errno \(err)): \(message)")
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
                if result < totalBytes {
                     KISSLinkLog.error(self.endpointDescription, message: "Partial write? \(result)/\(totalBytes) (Should be handled by loop)")
                }
                completion(nil)
            }
        }
    }

    /// Write raw bytes to the serial FD, bypassing the .connected state check.
    /// Used only during KISS init (before .connected is set) to send config frames and RESET.
    /// MUST be called on serialQueue.
    private func writeRaw(_ data: Data, completion: @escaping (Error?) -> Void) {
        let fd: Int32
        lock.lock()
        fd = fileDescriptor
        lock.unlock()

        guard fd >= 0 else {
            completion(KISSSerialError.notOpen)
            return
        }

        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        KISSLinkLog.info(endpointDescription, message: "KISS init writing \(data.count) bytes: \(hex)")

        var bytesWritten = 0
        let totalBytes = data.count

        let result = data.withUnsafeBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            while bytesWritten < totalBytes {
                let ptr = baseAddress.advanced(by: bytesWritten)
                let remaining = totalBytes - bytesWritten
                let count = Darwin.write(fd, ptr, remaining)
                if count < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let pollResult = poll(&pfd, 1, 500)
                        if pollResult > 0 { continue }
                        return -1
                    }
                    return -1
                }
                bytesWritten += count
            }
            return bytesWritten
        }

        if result < 0 {
            let err = errno
            let message = String(cString: strerror(err))
            KISSLinkLog.error(endpointDescription, message: "KISS init write failed (errno \(err)): \(message)")
            completion(KISSSerialError.writeFailed(message))
        } else {
            lock.lock()
            _totalBytesOut += result
            lock.unlock()
            completion(nil)
        }
    }

    /// Update configuration (e.g. when user changes settings).
    /// Only closes and reopens if transport-level settings changed (device path, baud rate).
    /// Mobilinkd-specific settings (gains, modem type) are stored in the config but
    /// do NOT trigger a reconnect — they're applied via EEPROM, not KISS init commands.
    func updateConfig(_ newConfig: SerialConfig) {
        serialQueue.async { [weak self] in
            guard let self else { return }
            let wasConnected: Bool
            self.lock.lock()
            wasConnected = self._state == .connected
            self.lock.unlock()

            let needsReconnect = wasConnected && (
                newConfig.devicePath != self.config.devicePath ||
                newConfig.baudRate != self.config.baudRate
            )

            self.config = newConfig

            if needsReconnect {
                KISSLinkLog.info(self.endpointDescription, message: "Transport config changed — reconnecting")
                self.closeInternal(reason: "Config changed")
                self.openInternal()
            } else if wasConnected {
                KISSLinkLog.info(self.endpointDescription, message: "Config updated (no reconnect needed)")
            }
        }
    }


    
    private var isConnecting = false
    
    private func openInternal() {
        lock.lock()
        let current = _state
        let alreadyConnecting = isConnecting
        lock.unlock()

        // Idempotency: if already connected or connecting, do nothing
        if current == .connected || alreadyConnecting {
            return
        }

        // Static Guard: Check if ANY instance is using this path
        KISSLinkSerial.pathLock.lock()
        if KISSLinkSerial.activePaths.contains(config.devicePath) {
            KISSLinkSerial.pathLock.unlock()
            KISSLinkLog.info(endpointDescription, message: "Suppressing concurrent open attempt (device path in use by another instance).")
            return
        }
        KISSLinkSerial.activePaths.insert(config.devicePath)
        KISSLinkSerial.pathLock.unlock()

        // Set connecting flag to prevent parallel attempts
        lock.lock()
        isConnecting = true
        lock.unlock()

        setState(.connecting)

        // Log "Opening..." only on first attempt to avoid spam
        if reconnectAttempt == 0 {
            KISSLinkLog.info(endpointDescription, message: "Opening serial port... [\(_shortID)]")
        } else {
             KISSLinkLog.info(endpointDescription, message: "Retry #\(reconnectAttempt) [\(_shortID)]")
        }

        // Verify device exists
        guard FileManager.default.fileExists(atPath: config.devicePath) else {
            cleanupOpenAttempt(success: false)
            setState(.failed)
            // Silent retry for missing device
            scheduleReconnectIfEnabled(initialDelay: 2.0)
            return
        }

        // Detect Bluetooth serial ports.
        // macOS Bluetooth serial driver creates /dev/cu.<DeviceName> for paired BT SPP devices.
        // The open() syscall blocks until the RFCOMM channel is established, even with O_NONBLOCK.
        // We must open on a detached thread with a timeout to avoid deadlocking the serial queue.
        let isBT = Self.isBluetoothSerialDevice(config.devicePath)
        isBluetoothSerial = isBT
        if isBT {
            KISSLinkLog.info(endpointDescription, message: "Detected Bluetooth serial port — using threaded open with \(Int(Self.btOpenTimeout))s timeout")
        }

        if isBT {
            openBluetoothSerial()
        } else {
            openUSBSerial()
        }
    }

    /// Check if a serial device is backed by the Bluetooth serial driver.
    /// Uses ioreg to check if the TTY name matches an IOBluetoothDevice.
    private static func isBluetoothSerialDevice(_ devicePath: String) -> Bool {
        // Extract the device name from path: /dev/cu.TNC4Mobilinkd -> TNC4Mobilinkd
        let deviceName = URL(fileURLWithPath: devicePath).lastPathComponent
        let ttyName: String
        if deviceName.hasPrefix("cu.") {
            ttyName = String(deviceName.dropFirst(3))
        } else if deviceName.hasPrefix("tty.") {
            ttyName = String(deviceName.dropFirst(4))
        } else {
            return false
        }

        // Check ioreg for a matching BTTTYName
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        proc.arguments = ["-r", "-c", "IOBluetoothDevice", "-l"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains("\"BTTTYName\" = \"\(ttyName)\"")
            }
        } catch {
            // If ioreg fails, fall back to heuristic
        }

        // Fallback heuristic: common BT serial device names don't contain "usbmodem" or "usbserial"
        let lower = devicePath.lowercased()
        if lower.contains("usbmodem") || lower.contains("usbserial") || lower.contains("wchusbserial") {
            return false
        }
        // Known BT devices
        if lower.contains("mobilinkd") {
            return true
        }
        return false
    }

    /// Open a Bluetooth serial port on a detached thread with a timeout.
    /// The macOS BT serial driver blocks open() until RFCOMM is established,
    /// which can hang indefinitely. This method prevents blocking the serial queue.
    private func openBluetoothSerial() {
        let path = config.devicePath
        let timeout = Self.btOpenTimeout

        // Dispatch the blocking open() to a global concurrent queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let sem = DispatchSemaphore(value: 0)
            var resultFD: Int32 = -1

            // The actual open() call — this may block for a long time
            let openThread = Thread {
                let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
                resultFD = fd
                sem.signal()
            }
            openThread.name = "BT-Serial-Open"
            openThread.start()

            let waitResult = sem.wait(timeout: .now() + timeout)

            if waitResult == .timedOut {
                // The open() is stuck in kernel space. We can't cancel it, but we
                // won't use the FD if it eventually returns. The thread will linger
                // until the BT connection times out or the device is power-cycled.
                KISSLinkLog.error(self.endpointDescription,
                    message: "Bluetooth serial open() timed out after \(Int(timeout))s. "
                           + "The TNC may need to be power-cycled.")
                self.serialQueue.async {
                    self.cleanupOpenAttempt(success: false)
                    self.setState(.failed)
                    self.notifyError("Bluetooth connection timed out — try power-cycling the TNC")
                    self.scheduleReconnectIfEnabled(initialDelay: 5.0)
                }
                return
            }

            // open() completed (either success or error)
            self.serialQueue.async {
                self.finishOpen(fd: resultFD)
            }
        }
    }

    /// Open a USB serial port directly on the serial queue.
    /// USB CDC serial open() with O_NONBLOCK returns immediately.
    private func openUSBSerial() {
        let fd = Darwin.open(config.devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        finishOpen(fd: fd)
    }

    /// Complete the open sequence after the file descriptor is obtained.
    /// Must be called on serialQueue.
    private func finishOpen(fd: Int32) {
        guard fd >= 0 else {
            let err = errno
            cleanupOpenAttempt(success: false)

            if err == EBUSY {
                KISSLinkLog.error(endpointDescription, message: "Port is busy (EBUSY). Held by another process?")
                setState(.failed)
                notifyError("Port Busy (held by another app)")
                scheduleReconnectIfEnabled(initialDelay: 1.0)

            } else if err == EAGAIN {
                KISSLinkLog.error(endpointDescription, message: "Port temporarily unavailable (EAGAIN).")
                setState(.failed)
                notifyError("Temporarily unavailable (retrying...)")
                scheduleReconnectIfEnabled(initialDelay: 1.0)

            } else {
                let errStr = String(cString: strerror(err))
                setState(.failed)
                notifyError("Failed to open: \(errStr)")
                scheduleReconnectIfEnabled(initialDelay: 1.0)
            }
            return
        }

        // Check that we haven't been closed while waiting for open to complete
        lock.lock()
        let stillConnecting = isConnecting
        lock.unlock()
        guard stillConnecting else {
            KISSLinkLog.info(endpointDescription, message: "Open completed but connection was cancelled, closing fd")
            Darwin.close(fd)
            cleanupOpenAttempt(success: false)
            return
        }

        // Configure the serial port
        configurePort(fd: fd)

        // Post-open stabilization delay.
        // TNC4 needs time to initialize after connection (USB CDC after DTR,
        // or Bluetooth RFCOMM after channel establishment).
        Thread.sleep(forTimeInterval: isBluetoothSerial ? 0.5 : 1.0)

        // Keep O_NONBLOCK set — DispatchSourceRead requires non-blocking FD
        // on macOS to properly deliver kqueue events for serial (character) devices.
        // The write path handles EAGAIN with a poll loop.

        lock.lock()
        fileDescriptor = fd
        _totalBytesIn = 0
        _totalBytesOut = 0
        lock.unlock()

        // Set up polling timer for reads.
        // We use a timer instead of DispatchSourceRead because kqueue-based
        // read sources on macOS do NOT reliably fire for unsolicited data on
        // USB CDC serial ports (e.g., Mobilinkd TNC4). The kqueue fires for
        // the initial response to our writes, but never fires for data the
        // device sends asynchronously (decoded radio frames). A 50ms poll
        // interval is more than adequate for 1200-baud packet radio.
        let pollTimer = DispatchSource.makeTimerSource(queue: serialQueue)
        pollTimer.schedule(deadline: .now() + 0.05, repeating: .milliseconds(50), leeway: .milliseconds(10))
        pollTimer.setEventHandler { [weak self] in
            self?.pollSerialPort()
        }

        // CLEANUP when timer is cancelled
        pollTimer.setCancelHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let currentFd = self.fileDescriptor
            let isBT = self.isBluetoothSerial
            self.lock.unlock()

            if currentFd >= 0 {
                // Restore original termios before closing (skip for BT serial)
                if !isBT {
                    var origTermios = self.originalTermios
                    tcsetattr(currentFd, TCSANOW, &origTermios)
                }
                Darwin.close(currentFd)
                self.lock.lock()
                self.fileDescriptor = -1
                self.lock.unlock()
            }

            KISSLinkLog.info(self.endpointDescription, message: "Port released [\(self._shortID)]")
        }

        lock.lock()
        readPollTimer = pollTimer
        lock.unlock()

        pollTimer.resume()

        cleanupOpenAttempt(success: true)
        KISSLinkLog.opened(endpointDescription)

        if isBluetoothSerial {
            KISSLinkLog.info(endpointDescription, message: "Bluetooth RFCOMM serial connected successfully")
        }

        // KISS init — goes straight to .connected (no commands sent to TNC)
        sendKISSInit()

        reconnectAttempt = 0
        cancelReconnectTimer()

        // Start Battery Polling if enabled
        if let mobiConfig = config.mobilinkdConfig, mobiConfig.isBatteryMonitoringEnabled {
            startBatteryPolling()
        }

        // NOTE: Do NOT auto-poll input levels — POLL_INPUT_LEVEL (0x04)
        // stops the TNC4 demodulator. Use manual one-shot measurement only.
    }
    
    private func startBatteryPolling() {
        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer.schedule(deadline: .now() + 5.0, repeating: 60.0) // First poll after 5s, then every 60s
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let frame = MobilinkdTNC.pollBatteryLevel()
            // Send directly without queuing if possible, or use standard send
            self.send(Data(frame)) { _ in } 
        }
        timer.resume()
        
        lock.lock()
        batteryPollTimer = timer
        lock.unlock()
    }

    private func cleanupOpenAttempt(success: Bool) {
        lock.lock()
        isConnecting = false
        lock.unlock()
        
        if !success {
            // Release static guard if we failed to open
            KISSLinkSerial.pathLock.lock()
            KISSLinkSerial.activePaths.remove(config.devicePath)
            KISSLinkSerial.pathLock.unlock()
        }
    }
    
    /// Placeholder for finding process holding port
    private func findProcessHoldingPort(path: String) -> String? {
        return nil
    }

    private func sendKISSInit() {
        // TNC4 KISS Init Strategy — ZERO DISRUPTION:
        //
        // The TNC4 auto-starts its demodulator on USB connect (and BLE connect).
        // The EEPROM holds calibrated gain/twist/DC-offset from ADJUST_INPUT_LEVELS.
        // Sending ANY commands on connect (RESET, SET_MODEM_TYPE, gain commands,
        // even standard KISS params) risks disrupting the already-running demodulator.
        //
        // qth.app and other working KISS clients don't send init commands — they
        // just open the port and start listening. We do the same.
        //
        // Go straight to .connected and let the auto-started demodulator do its job.

        if config.mobilinkdConfig != nil {
            KISSLinkLog.info(endpointDescription, message: "Mobilinkd serial detected — sending NO init commands (EEPROM config + auto-start demodulator)")
        } else {
            KISSLinkLog.info(endpointDescription, message: "Serial connected — no KISS init needed")
        }

        setState(.connected)
        KISSLinkLog.info(endpointDescription, message: "KISS init complete — link ready (no commands sent)")
    }

    /// Build a raw KISS frame: FEND + type + SLIP-escaped payload + FEND
    private func kissFrame(type: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0xC0, type]
        for byte in payload {
            if byte == 0xC0 {
                frame.append(contentsOf: [0xDB, 0xDC])
            } else if byte == 0xDB {
                frame.append(contentsOf: [0xDB, 0xDD])
            } else {
                frame.append(byte)
            }
        }
        frame.append(0xC0)
        return frame
    }

    /// Cancel any in-flight KISS init work items (POLL/RESET sequence).
    private func cancelKISSInit() {
        lock.lock()
        let work = kissInitWorkItem
        kissInitWorkItem = nil
        lock.unlock()
        work?.cancel()
    }

    // MARK: - Private: Configure Port

    private func configurePort(fd: Int32) {
        if isBluetoothSerial {
            // Bluetooth RFCOMM serial: termios settings (baud rate, flow control, DTR/RTS)
            // are irrelevant — the Bluetooth stack handles framing and flow control.
            // We only need raw mode and VMIN/VTIME for non-blocking reads.
            KISSLinkLog.info(endpointDescription, message: "Bluetooth serial — skipping baud/DTR/RTS config")

            // Still try tcgetattr/tcsetattr for raw mode — the BT serial driver
            // usually supports these even though baud rate is meaningless.
            var options = termios()
            if tcgetattr(fd, &options) == 0 {
                originalTermios = options
                cfmakeraw(&options)
                options.c_cflag |= UInt(CLOCAL | CREAD)
                options.c_cc.16 = 0   // VMIN
                options.c_cc.17 = 0   // VTIME
                if tcsetattr(fd, TCSANOW, &options) == 0 {
                    KISSLinkLog.info(endpointDescription, message: "BT serial: raw mode set")
                } else {
                    KISSLinkLog.info(endpointDescription, message: "BT serial: tcsetattr failed (non-fatal): \(String(cString: strerror(errno)))")
                }
            } else {
                KISSLinkLog.info(endpointDescription, message: "BT serial: tcgetattr failed (non-fatal): \(String(cString: strerror(errno)))")
            }

            tcflush(fd, TCIOFLUSH)
            return
        }

        // USB serial: full termios configuration
        if tcgetattr(fd, &originalTermios) != 0 {
            KISSLinkLog.error(endpointDescription, message: "tcgetattr failed: \(String(cString: strerror(errno))) (non-fatal)")
        }

        var options = termios()
        if tcgetattr(fd, &options) != 0 {
            KISSLinkLog.error(endpointDescription, message: "tcgetattr failed (non-fatal)")
            return
        }

        // Raw mode - no echo, no signals, no canonical processing
        cfmakeraw(&options)

        // Set baud rate
        let speed = config.posixBaudRate
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)

        // 8N1: 8 data bits, no parity, 1 stop bit
        options.c_cflag |= UInt(CS8)
        options.c_cflag &= ~UInt(PARENB)
        options.c_cflag &= ~UInt(CSTOPB)

        // FLOW CONTROL: Explicitly Disable All
        options.c_cflag &= ~UInt(CRTSCTS)
        options.c_iflag &= ~UInt(IXON | IXOFF | IXANY)

        // Assert CLOCAL (ignore modem status lines) and CREAD (enable receiver)
        options.c_cflag |= UInt(CLOCAL | CREAD)

        // VMIN=0, VTIME=0 -> Non-blocking reads (return immediately with available data).
        // Required because we keep O_NONBLOCK set for DispatchSourceRead compatibility.
        options.c_cc.16 = 0   // VMIN
        options.c_cc.17 = 0   // VTIME

        if tcsetattr(fd, TCSANOW, &options) != 0 {
            KISSLinkLog.error(endpointDescription, message: "tcsetattr failed (non-fatal): \(String(cString: strerror(errno)))")
        }

        // Log configuration for debugging TNC issues
        KISSLinkLog.info(endpointDescription, message: "Serial Configured: Baud \(config.baudRate), 8N1, NoFlow. c_cflag=\(String(format: "%x", options.c_cflag)) c_iflag=\(String(format: "%x", options.c_iflag))")

        // Flush any stale data
        tcflush(fd, TCIOFLUSH)

        // Assert DTR and RTS
        // Many TNCs/Radios require DTR to be high to accept data or power the interface.
        var bits: Int32 = 0x002 | 0x004 // TIOCM_DTR | TIOCM_RTS
        if ioctl(fd, 0x8004746c, &bits) == -1 {
             KISSLinkLog.error(endpointDescription, message: "Failed to assert DTR/RTS: \(String(cString: strerror(errno)))")
        } else {
             KISSLinkLog.info(endpointDescription, message: "Asserted DTR & RTS")
        }
    }

    // MARK: - Private: Read

    private var readEventCount = 0
    private var pollCount = 0

    /// Poll the serial port for available data. Called by the read poll timer
    /// every 50ms. Reads ALL available data in a loop until no more is available.
    /// This replaces DispatchSourceRead which doesn't reliably fire for
    /// unsolicited data on macOS USB CDC serial ports.
    ///
    /// IMPORTANT: On macOS USB CDC serial with O_NONBLOCK + VMIN=0/VTIME=0,
    /// read() returns 0 when no data is available (NOT -1/EAGAIN). This is
    /// because the termios layer returns "0 bytes available" before the
    /// O_NONBLOCK layer can return EAGAIN. We must NOT treat 0 as EOF.
    /// Device disconnect is detected via ENXIO/EIO errors or file existence.
    private func pollSerialPort() {
        lock.lock()
        let fd = fileDescriptor
        lock.unlock()

        guard fd >= 0 else { return }

        pollCount += 1
        var buffer = [UInt8](repeating: 0, count: 4096)

        // Read all available data in a tight loop
        while true {
            let bytesRead = Darwin.read(fd, &buffer, buffer.count)

            if bytesRead > 0 {
                readEventCount += 1
                let data = Data(buffer[0..<bytesRead])
                lock.lock()
                _totalBytesIn += bytesRead
                lock.unlock()

                let hex = data.prefix(128).map { String(format: "%02X", $0) }.joined(separator: " ")
                KISSLinkLog.info(endpointDescription, message: "RX[\(readEventCount)] \(bytesRead) bytes: \(hex)\(data.count > 128 ? "..." : "")")
                KISSLinkLog.bytesIn(endpointDescription, count: bytesRead)
                Task { @MainActor [weak self] in
                    self?.delegate?.linkDidReceive(data)
                }
            } else if bytesRead == 0 {
                // On USB CDC serial with O_NONBLOCK + VMIN=0/VTIME=0, read()
                // returns 0 when no data is available. This is NOT EOF.
                // (Same behavior as MinimalTNC4ConnectTest.readAllAvailable)
                break
            } else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // No more data available — normal for non-blocking fd
                    break
                } else {
                    let message = String(cString: strerror(err))
                    KISSLinkLog.error(endpointDescription, message: "Read error at poll #\(pollCount): \(message)")
                    if err == ENXIO || err == EIO {
                        handleDeviceDisconnect()
                    }
                    return
                }
            }
        }

        // Periodic device existence check (every ~5s = every 100 polls)
        if pollCount % 100 == 0 {
            if !FileManager.default.fileExists(atPath: config.devicePath) {
                KISSLinkLog.info(endpointDescription, message: "Device file disappeared at poll #\(pollCount)")
                handleDeviceDisconnect()
            }
        }
    }

    // MARK: - Private: Close

    private func closeInternal(reason: String) {
        cancelKISSInit()
        cancelReconnectTimer()

        lock.lock()
        batteryPollTimer?.cancel()
        batteryPollTimer = nil
        let timer = readPollTimer
        readPollTimer = nil
        let fd = fileDescriptor
        lock.unlock()

        // Always release the static guard synchronously so that an immediate
        // reopen (e.g. from updateConfig) can proceed without waiting for the
        // async cancel handler.
        KISSLinkSerial.pathLock.lock()
        KISSLinkSerial.activePaths.remove(config.devicePath)
        KISSLinkSerial.pathLock.unlock()

        if let timer = timer {
            timer.cancel() // Cancel handler will close fd and restore termios
        } else if fd >= 0 {
            // If no source was set up, close directly
            if !isBluetoothSerial {
                var origTermios = originalTermios
                tcsetattr(fd, TCSANOW, &origTermios)
            }
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

    private func scheduleReconnectIfEnabled(initialDelay: TimeInterval? = nil) {
        guard config.autoReconnect else { return }

        reconnectAttempt += 1
        
        let backoff = min(
            Self.baseReconnectDelay * pow(2, Double(reconnectAttempt - 1)),
            Self.maxReconnectDelay
        )
        
        // Use initialDelay if provided (e.g. for EBUSY), otherwise calculated backoff
        // Add random jitter to prevent thundering herd if multiple things reconnect
        let jitter = Double.random(in: 0...0.5)
        let delay = (initialDelay ?? backoff) + jitter

        KISSLinkLog.reconnect(endpointDescription, attempt: reconnectAttempt)

        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Check if device is present/available before trying
            if FileManager.default.fileExists(atPath: self.config.devicePath) {
                self.openInternal()
            } else {
                // Device still missing, schedule next check (count as attempt)
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

