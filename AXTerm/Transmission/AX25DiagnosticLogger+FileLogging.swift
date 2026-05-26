//
//  AX25DiagnosticLogger+FileLogging.swift
//  AXTerm
//
//  Adds file logging capability to the diagnostic logger.
//  Logs are written to Application Support directory for easy access.
//

import AppKit
import Foundation
import OSLog

// MARK: - File Logger

/// Handles writing diagnostic logs to a file
actor DiagnosticFileLogger {
    static let shared = DiagnosticFileLogger()
    
    private var fileHandle: FileHandle?
    private var logFileURL: URL?
    private var isEnabled = false
    
    private init() {}
    
    // MARK: - Setup
    
    func enable() throws {
        guard !isEnabled else { return }
        
        let fileURL = try createLogFile()
        self.logFileURL = fileURL
        
        // Open file for writing
        if FileManager.default.fileExists(atPath: fileURL.path) {
            fileHandle = try FileHandle(forWritingTo: fileURL)
            try fileHandle?.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: fileURL)
        }
        
        isEnabled = true
        
        // Write header
        let header = """
        ================================================================================
        AXTerm Diagnostic Log
        Started: \(Date().ISO8601Format())
        Session ID: \(UUID().uuidString.prefix(8))
        ================================================================================
        
        """
        try write(header)
        
        print("📝 Diagnostic log file: \(fileURL.path)")
    }
    
    func disable() {
        guard isEnabled else { return }
        
        do {
            try fileHandle?.close()
        } catch {
            print("Error closing log file: \(error)")
        }
        
        fileHandle = nil
        isEnabled = false
    }
    
    // MARK: - File Management
    
    private func createLogFile() throws -> URL {
        // Get Application Support directory
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        
        // Create AXTerm directory
        let axTermDir = appSupport.appendingPathComponent("AXTerm", isDirectory: true)
        try FileManager.default.createDirectory(at: axTermDir, withIntermediateDirectories: true)
        
        // Create Logs directory
        let logsDir = axTermDir.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        // Generate log filename with timestamp
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let filename = "ax25-diagnostic-\(timestamp).log"
        
        let logFileURL = logsDir.appendingPathComponent(filename)
        
        // Clean up old log files (keep last 10)
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
        
        // Keep last 10 logs, delete older ones
        if logFiles.count > 10 {
            for file in logFiles.dropFirst(10) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    
    // MARK: - Writing
    
    func write(_ message: String) throws {
        guard isEnabled, let fileHandle else { return }
        
        let timestamp = Date().ISO8601Format()
        let logLine = "[\(timestamp)] \(message)\n"
        
        if let data = logLine.data(using: .utf8) {
            try fileHandle.write(contentsOf: data)
        }
    }
    
    func writeWithHexDump(_ message: String, data: Data) throws {
        try write(message)
        try write(hexDump(data))
    }
    
    private func hexDump(_ data: Data) -> String {
        var result = "Hex dump (\(data.count) bytes):\n"
        var offset = 0
        
        while offset < data.count {
            result += String(format: "%04X: ", offset)
            
            let lineEnd = min(offset + 16, data.count)
            for i in offset..<lineEnd {
                result += String(format: "%02X ", data[i])
                if i == offset + 7 {
                    result += " "
                }
            }
            
            if lineEnd - offset < 16 {
                let missing = 16 - (lineEnd - offset)
                result += String(repeating: "   ", count: missing)
                if lineEnd - offset < 8 {
                    result += " "
                }
            }
            
            result += " |"
            for i in offset..<lineEnd {
                let byte = data[i]
                if byte >= 32 && byte <= 126 {
                    result += String(format: "%c", byte)
                } else {
                    result += "."
                }
            }
            result += "|\n"
            
            offset = lineEnd
        }
        
        return result
    }
    
    // MARK: - File Access
    
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
    
    func getLogFileSize() -> Int64? {
        guard let url = logFileURL else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.size] as? Int64
    }
}

// MARK: - Enhanced Logger with File Support

extension AX25DiagnosticLogger {
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
    
    /// Write a log entry to file (called internally)
    internal func writeToFile(_ message: String) {
        Task {
            try? await DiagnosticFileLogger.shared.write(message)
        }
    }
    
    /// Write a log entry with hex dump to file
    internal func writeToFileWithHexDump(_ message: String, data: Data) {
        Task {
            try? await DiagnosticFileLogger.shared.writeWithHexDump(message, data: data)
        }
    }
}

// MARK: - Auto-Enable Configuration

extension AX25DiagnosticConfig {
    /// Configuration with file logging enabled
    static var standardWithFile: Self {
        var config = standard
        // File logging is enabled separately via enableFileLogging()
        return config
    }
    
    static var comprehensiveWithFile: Self {
        var config = comprehensive
        return config
    }
}

// MARK: - Automatic Setup Helper

/// Automatically configure diagnostic logging based on build configuration
enum DiagnosticLoggerSetup {
    /// Configure and enable diagnostic logging automatically
    static func configure() {
        #if DEBUG
        // Debug builds: Comprehensive logging + file logging
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(.comprehensive)
            try? await AX25DiagnosticLogger.shared.enableFileLogging()
            print("🔍 Debug Mode: Comprehensive diagnostic logging enabled")
            if let logURL = await AX25DiagnosticLogger.shared.getLogFileURL() {
                print("📝 Log file: \(logURL.path)")
            }
        }
        #else
        // Release builds: Standard logging, no file logging (unless explicitly enabled)
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(.standard)
            print("📊 Release Mode: Standard diagnostic logging enabled")
        }
        #endif
    }
    
    /// Configure with custom options
    static func configure(enableFileLogging: Bool = true, config: AX25DiagnosticConfig = .standard) {
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(config)
            if enableFileLogging {
                try? await AX25DiagnosticLogger.shared.enableFileLogging()
            }
        }
    }
}

// MARK: - Updated Integration

extension AX25DiagnosticLogger {
    /// Enhanced log function with file output
    private func logWithFile(
        _ level: AX25DiagnosticLevel,
        category: String,
        message: String,
        endpoint: String? = nil,
        data: Data? = nil,
        metadata: [String: String] = [:]
    ) {
        // Log to OSLog via the public convenience method
        let fullMessage = "[\(category)] \(message)"
        AX25DiagnosticLogger.log(level, fullMessage, endpoint: endpoint)
        
        // Also write to file
        let levelName = level.name
        var fileMessage = "[\(levelName)] [\(category)]"
        if let endpoint {
            fileMessage += " [\(endpoint)]"
        }
        fileMessage += " \(message)"
        
        if !metadata.isEmpty {
            let metaStr = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            fileMessage += " {\(metaStr)}"
        }
        
        if let data, !data.isEmpty {
            writeToFileWithHexDump(fileMessage, data: data)
        } else {
            writeToFile(fileMessage)
        }
    }
}
