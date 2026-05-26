//
//  ADD_TO_AX25DiagnosticLogger.swift
//  AXTerm
//
//  Add these methods and the file logger to AX25DiagnosticLogger.swift
//

// MARK: - File Logger (Add this BEFORE the AX25DiagnosticLogger actor)

/// Handles writing diagnostic logs to a file
actor DiagnosticFileLogger {
    static let shared = DiagnosticFileLogger()
    
    private var fileHandle: FileHandle?
    private var logFileURL: URL?
    private var isEnabled = false
    
    private init() {}
    
    func enable() async throws {
        guard !isEnabled else { return }
        
        let fileURL = try createLogFile()
        self.logFileURL = fileURL
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            fileHandle = try FileHandle(forWritingTo: fileURL)
            try fileHandle?.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: fileURL)
        }
        
        isEnabled = true
        
        let header = """
        ================================================================================
        AXTerm Diagnostic Log
        Started: \(Date().ISO8601Format())
        ================================================================================
        
        """
        try write(header)
        
        print("📝 Diagnostic log file: \(fileURL.path)")
    }
    
    func disable() async {
        guard isEnabled else { return }
        try? fileHandle?.close()
        fileHandle = nil
        isEnabled = false
    }
    
    private func createLogFile() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        
        let axTermDir = appSupport.appendingPathComponent("AXTerm", isDirectory: true)
        try FileManager.default.createDirectory(at: axTermDir, withIntermediateDirectories: true)
        
        let logsDir = axTermDir.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let filename = "ax25-diagnostic-\(timestamp).log"
        
        let logFileURL = logsDir.appendingPathComponent(filename)
        
        try cleanupOldLogs(in: logsDir)
        
        return logFileURL
    }
    
    private func cleanupOldLogs(in directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )
        
        let logFiles = files
            .filter { $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix("ax25-diagnostic-") }
            .sorted { (url1, url2) -> Bool in
                guard let date1 = try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate,
                      let date2 = try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate else {
                    return false
                }
                return date1 > date2
            }
        
        if logFiles.count > 10 {
            for file in logFiles.dropFirst(10) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    
    func write(_ message: String) throws {
        guard isEnabled, let fileHandle else { return }
        
        let timestamp = Date().ISO8601Format()
        let logLine = "[\(timestamp)] \(message)\n"
        
        if let data = logLine.data(using: .utf8) {
            try fileHandle.write(contentsOf: data)
        }
    }
    
    func getLogFileURL() -> URL? {
        logFileURL
    }
    
    func openLogFile() {
        guard let url = logFileURL else { return }
        NSWorkspace.shared.open(url)
    }
    
    func revealLogFile() {
        guard let url = logFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Add these methods to AX25DiagnosticLogger actor

extension AX25DiagnosticLogger {
    // MARK: - File Logging
    
    /// Enable file logging in addition to OSLog
    func enableFileLogging() async throws {
        try await DiagnosticFileLogger.shared.enable()
        await logInfo("File logging enabled")
    }
    
    /// Disable file logging
    func disableFileLogging() async {
        await DiagnosticFileLogger.shared.disable()
        await logInfo("File logging disabled")
    }
    
    /// Get the current log file URL
    func getLogFileURL() async -> URL? {
        await DiagnosticFileLogger.shared.getLogFileURL()
    }
    
    /// Open the log file in default text editor
    func openLogFile() async {
        await DiagnosticFileLogger.shared.openLogFile()
    }
    
    /// Reveal the log file in Finder
    func revealLogFile() async {
        await DiagnosticFileLogger.shared.revealLogFile()
    }
    
    /// Write to file (called automatically by log methods)
    private func writeToFile(_ message: String) {
        Task {
            try? await DiagnosticFileLogger.shared.write(message)
        }
    }
}

// MARK: - MODIFY the existing log() method in AX25DiagnosticLogger

/*
 Find the existing log() method and ADD this at the end, right before the
 switch statement that logs to OSLog:
 */

func logWithFileOutput(
    _ level: AX25DiagnosticLevel,
    category: String,
    message: String,
    endpoint: String? = nil,
    data: Data? = nil,
    metadata: [String: String] = [:]
) {
    guard level >= config.minimumLevel else { return }
    
    var logMessage = "[\(category)]"
    if let endpoint {
        logMessage += " [\(endpoint)]"
    }
    logMessage += " \(message)"
    
    // Add metadata
    if !metadata.isEmpty {
        let metaStr = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        logMessage += " {\(metaStr)}"
    }
    
    // Write to file BEFORE hex dump
    writeToFile(logMessage)
    
    // Add hex dump if enabled and data present
    if let data, !data.isEmpty, config.enableHexDumps {
        let dumpData = config.maxHexDumpBytes > 0 ? data.prefix(config.maxHexDumpBytes) : data
        let hexDumpString = hexDump(dumpData)
        logMessage += "\n" + hexDumpString
        
        // Write hex dump to file
        writeToFile(hexDumpString)
        
        if config.maxHexDumpBytes > 0 && data.count > config.maxHexDumpBytes {
            let truncMsg = "... (\(data.count - config.maxHexDumpBytes) more bytes)"
            logMessage += "\n" + truncMsg
            writeToFile(truncMsg)
        }
    }
    
    // Continue with existing OSLog code...
    switch level {
    case .verbose:
        logger.debug("\(logMessage, privacy: .public)")
    case .debug:
        logger.debug("\(logMessage, privacy: .public)")
    case .info:
        logger.info("\(logMessage, privacy: .public)")
    case .warning:
        logger.warning("\(logMessage, privacy: .public)")
    case .error:
        logger.error("\(logMessage, privacy: .public)")
    }
}

// MARK: - Usage

/*
 
 INTEGRATION STEPS:
 
 1. Add the DiagnosticFileLogger actor BEFORE AX25DiagnosticLogger in the same file
 
 2. Add the extension methods to AX25DiagnosticLogger
 
 3. Modify the existing log() method to call writeToFile()
    OR rename the existing log() to logInternal() and add a new log() that calls both
 
 4. In your app startup code:
 
    @main
    struct AXTermApp: App {
        init() {
            #if DEBUG
            Task {
                await AX25DiagnosticLogger.shared.updateConfig(.comprehensive)
                try? await AX25DiagnosticLogger.shared.enableFileLogging()
                
                if let logURL = await AX25DiagnosticLogger.shared.getLogFileURL() {
                    print("📝 Log file: \(logURL.path)")
                }
            }
            #else
            Task {
                await AX25DiagnosticLogger.shared.updateConfig(.standard)
            }
            #endif
        }
    }
 
 5. Logs will now be written to:
    ~/Library/Application Support/AXTerm/Logs/ax25-diagnostic-YYYY-MM-DD_HHMMSS.log
 
 */
