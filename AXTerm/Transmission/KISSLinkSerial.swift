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
    private var readSource: DispatchSourceRead?
    private let serialQueue = DispatchQueue(label: "com.axterm.kisslink.serial", qos: .userInitiated)
    private var reconnectTimer: DispatchSourceTimer?
    private var batteryPollTimer: DispatchSourceTimer?
    private var reconnectAttempt = 0
    private static let maxReconnectDelay: TimeInterval = 15 // Cap at 15s per requirements
    private static let baseReconnectDelay: TimeInterval = 1
    private var originalTermios = termios()

    // MARK: - Stats

    private var _totalBytesIn = 0
    private var _totalBytesOut = 0
    
    // ...

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
                        if err == EINTR { continue } // Interrupted, retry
                        if err == EAGAIN {
                            // In blocking mode (which we are), this shouldn't happen unless O_NONBLOCK is somehow set.
                            // If it does, we should probably wait/select, but for now treat as error or busy loop (bad).
                            // Given we cleared O_NONBLOCK in openInternal, this is a real error.
                             KISSLinkLog.error(self.endpointDescription, message: "Write EAGAIN (unexpected in blocking mode)")
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

        // Open the serial device
        // O_NONBLOCK is essential to avoid hanging
        let fd = Darwin.open(config.devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK | O_EXLOCK)
        
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

        // Configure the serial port
        do {
            try configurePort(fd: fd)
            // TNC4 (and possibly others) needs time to initialize USB CDC after DTR is asserted.
            // Without this pause, early frames (like KISS Init) may be dropped by the firmware.
            Thread.sleep(forTimeInterval: 1.0)
        } catch {
            Darwin.close(fd)
            cleanupOpenAttempt(success: false)
            setState(.failed)
            notifyError(error.localizedDescription)
            scheduleReconnectIfEnabled(initialDelay: 1.0)
            return
        }

        // Clear O_NONBLOCK
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
        
        // CLEANUP when source is cancelled
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
            
            // Release static guard
            KISSLinkSerial.pathLock.lock()
            KISSLinkSerial.activePaths.remove(self.config.devicePath)
            KISSLinkSerial.pathLock.unlock()
            
            KISSLinkLog.info(self.endpointDescription, message: "Port released [\(self._shortID)]")
        }

        lock.lock()
        readSource = source
        lock.unlock()

        source.resume()
        
        cleanupOpenAttempt(success: true)
        setState(.connected)
        KISSLinkLog.opened(endpointDescription)
        
        // Send KISS Init Sequence (TX Delay etc)
        sendKISSInit()
        
        reconnectAttempt = 0
        cancelReconnectTimer()
        
        // Start Battery Polling if enabled
        if let mobiConfig = config.mobilinkdConfig, mobiConfig.isBatteryMonitoringEnabled {
            startBatteryPolling()
        }
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
        // TNC4 Configuration Sequence
        // We configure the TNC to be aggressive about transmitting, ignoring DCD if possible.
        
        var frames: [[UInt8]] = [
            // 1. Set Duplex = 1 (Full Duplex).
            //    Most TNCs use this to ignore DCD (Carrier Detect) and transmit immediately.
            //    Critical for TNC4 if squelch/DCD is stuck open.
            [0xC0, 0x05, 0x01, 0xC0],
            
            // 2. Set Persistence = 255 (0xFF).
            //    Probability of transmitting = 100%. Don't wait for random slots.
            [0xC0, 0x02, 0xFF, 0xC0],
            
            // 3. Set Slot Time = 0 (0x00).
            //    No delay between checks.
            [0xC0, 0x03, 0x00, 0xC0],
            
            // 4. Set TX Delay = 30 (300ms).
            //    Give radio time to key up before data.
            [0xC0, 0x01, 30, 0xC0]
        ]
        
        // Mobilinkd Specific Configuration
        if let mobiConfig = config.mobilinkdConfig {
            KISSLinkLog.info(endpointDescription, message: "Applying Mobilinkd Config: \(mobiConfig.modemType.description), Out=\(mobiConfig.outputGain), In=\(mobiConfig.inputGain)")
            
            // Set Modem Type
            frames.append(MobilinkdTNC.setModemType(mobiConfig.modemType))
            
            // Set Output Gain (TX Volume)
            frames.append(MobilinkdTNC.setOutputGain(mobiConfig.outputGain))
            
            // Set Input Gain (RX Volume)
            frames.append(MobilinkdTNC.setInputGain(mobiConfig.inputGain))
            
        } else {
            // Default rudimentary config if not explicitly configured as Mobilinkd but we suspect it is TNC4
             // 5. Set Output Gain (TX Volume) -> Hardware Command 0x06, Subcommand 0x01
             //    Setting to 128 (0x0080) approx half scale to ensure it's not silent.
             frames.append([0xC0, 0x06, 0x01, 0x00, 0x80, 0xC0])
             
             // 6. Set Input Gain (RX Volume) -> Hardware Command 0x06, Subcommand 0x02
             //    Setting to 4 (0x0004).
             frames.append([0xC0, 0x06, 0x02, 0x00, 0x04, 0xC0])
            
            KISSLinkLog.info(endpointDescription, message: "Sending Default TNC Configuration (Duplex=1, P=255, Slot=0, Vol=128)")
        }
        
        // Send all config frames in sequence
        for (index, frame) in frames.enumerated() {
            // Small stagger to ensure firmware processes each command
            let delay = Double(index) * 0.1
            serialQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.send(Data(frame)) { err in
                    if let err = err {
                        KISSLinkLog.error(self?.endpointDescription ?? "Serial", message: "Failed to send config frame \(index): \(err.localizedDescription)")
                    }
                }
            }
        }
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

        // Set baud rate (Force 115200 for Mobilinkd compatibility if not otherwise specified, though config usually carries it)
        // config.posixBaudRate handles the mapping.
        let speed = config.posixBaudRate
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)

        // 8N1: 8 data bits, no parity, 1 stop bit
        options.c_cflag |= UInt(CS8)
        options.c_cflag &= ~UInt(PARENB)   // No parity
        options.c_cflag &= ~UInt(CSTOPB)   // 1 stop bit
        
        // FLOW CONTROL: Explicitly Disable All
        options.c_cflag &= ~UInt(CRTSCTS)       // No HW flow control
        options.c_iflag &= ~UInt(IXON | IXOFF | IXANY) // No SW flow control
        
        // Assert CLOCAL (ignore modem status lines) and CREAD (enable receiver)
        options.c_cflag |= UInt(CLOCAL | CREAD)
        
        // Valid for partial reads if strictly needed, but we use non-blocking or select usually.
        // Here we configure for blocking read with timeout for safety?
        // Actually we use DispatchSource which implies O_NONBLOCK usually, but we clear it in openInternal.
        // When using DispatchSourceRead, the FD should ideally be O_NONBLOCK, but for Write we want blocking?
        // Wait, if we clear O_NONBLOCK, DispatchSource might misbehave or block a thread?
        // Re-reading DispatchSource docs: It supports blocking FDs but it's better to be non-blocking.
        // HOWEVER, the previous code cleared O_NONBLOCK. Let's stick to that but ensure VMIN/VTIME are safe.

        // VMIN=1, VTIME=0 -> Blocking read until at least 1 byte.
        // This effectively makes the DispatchSource callback fire only when data is available...
        // ...but wait, DispatchSourceRead monitors specific events.
        // Ideally:
        options.c_cc.16 = 1   // VMIN
        options.c_cc.17 = 0   // VTIME

        if tcsetattr(fd, TCSANOW, &options) != 0 {
            throw KISSSerialError.configurationFailed("tcsetattr failed: \(String(cString: strerror(errno)))")
        }
        
        // Log configuration for debugging TNC issues
        KISSLinkLog.info(endpointDescription, message: "Serial Configured: Baud \(config.baudRate), 8N1, NoFlow. c_cflag=\(String(format: "%x", options.c_cflag)) c_iflag=\(String(format: "%x", options.c_iflag))")

        // Flush any stale data
        tcflush(fd, TCIOFLUSH)
        
        // Assert DTR and RTS
        // Many TNCs/Radios require DTR to be high to accept data or power the interface.
        // POSIX constants for macOS (from ioctl.h):
        // TIOCMBIS = 0x8004746c
        // TIOCM_DTR = 0x002
        // TIOCM_RTS = 0x004
        var bits: Int32 = 0x002 | 0x004 // TIOCM_DTR | TIOCM_RTS
        if ioctl(fd, 0x8004746c, &bits) == -1 {
             KISSLinkLog.error(endpointDescription, message: "Failed to assert DTR/RTS: \(String(cString: strerror(errno)))")
        } else {
             KISSLinkLog.info(endpointDescription, message: "Asserted DTR & RTS")
        }
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
        batteryPollTimer?.cancel()
        batteryPollTimer = nil
        let source = readSource
        readSource = nil
        let fd = fileDescriptor
        lock.unlock()

        if let source = source {
            source.cancel() // Cancel handler will close fd and remove static guard
        } else if fd >= 0 {
            // If no source was set up, close directly
            var origTermios = originalTermios
            tcsetattr(fd, TCSANOW, &origTermios)
            Darwin.close(fd)
            lock.lock()
            fileDescriptor = -1
            lock.unlock()
            
            // RELEASE GUARD MANUALLY since no cancel handler runs
            KISSLinkSerial.pathLock.lock()
            KISSLinkSerial.activePaths.remove(config.devicePath)
            KISSLinkSerial.pathLock.unlock()
        } else {
             // If we were failed/connecting, ensure guard is released?
             // cleanupOpenAttempt should have handled it, but safety check:
             if !isConnecting {
                KISSLinkSerial.pathLock.lock()
                KISSLinkSerial.activePaths.remove(config.devicePath)
                KISSLinkSerial.pathLock.unlock()
             }
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

