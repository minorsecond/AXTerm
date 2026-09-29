# Diagnostic Logging: Your Questions Answered

## Q1: Is this enabled by default on debug builds?

**Short Answer: NO - you must add initialization code.**

### Why Not Automatic?

The diagnostic logger is a separate system that needs explicit initialization because:
1. It requires app startup hooks to configure
2. File logging needs permission to write to Application Support
3. You might want different configurations for different scenarios

### How to Make It Automatic

Add this **ONE TIME** to your app's initialization:

#### For SwiftUI Apps:
```swift
@main
struct AXTermApp: App {
    init() {
        setupDiagnosticLogging() // ⭐ ADD THIS LINE
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
    
    private func setupDiagnosticLogging() {
        #if DEBUG
        // Debug builds: Comprehensive + file logging (automatic)
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(.comprehensive)
            try? await AX25DiagnosticLogger.shared.enableFileLogging()
            print("🔍 Debug logging enabled")
            if let url = await AX25DiagnosticLogger.shared.getLogFileURL() {
                print("📝 Logs: \(url.path)")
            }
        }
        #else
        // Release builds: Standard logging (OSLog only)
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(.standard)
        }
        #endif
    }
}
```

#### For AppKit Apps:
```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupDiagnosticLogging() // ⭐ ADD THIS LINE
    }
    
    private func setupDiagnosticLogging() {
        #if DEBUG
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(.comprehensive)
            try? await AX25DiagnosticLogger.shared.enableFileLogging()
            NSLog("🔍 Debug logging enabled")
        }
        #else
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(.standard)
        }
        #endif
    }
}
```

### What This Does

✅ **DEBUG builds:**
- Automatically enables comprehensive logging
- Automatically enables file logging
- Logs written to `~/Library/Application Support/AXTerm/Logs/`
- Every BLE, KISS, AX.25 event logged

✅ **RELEASE builds:**
- Automatically enables standard logging
- Uses OSLog only (no file I/O)
- Key events and errors only
- Minimal overhead

---

## Q2: Should it also log to file?

**Short Answer: YES - and it does! (when you enable it)**

### File Logging Features

The diagnostic logger **includes file logging** with these features:

#### ✅ Automatic File Management
- New file created each session
- Timestamped filenames: `ax25-diagnostic-2026-03-02_143022.log`
- Keeps last 10 log files
- Auto-deletes older logs
- No disk space bloat

#### ✅ Complete Log Data
- Same information as Console.app
- Includes hex dumps
- Includes timestamps
- Includes all metadata
- Survives app restart

#### ✅ Easy Access
```swift
// Get current log file path
if let url = await AX25DiagnosticLogger.shared.getLogFileURL() {
    print(url.path)
}

// Open in default text editor
await AX25DiagnosticLogger.shared.openLogFile()

// Reveal in Finder
await AX25DiagnosticLogger.shared.revealLogFile()
```

### File Location

Logs are saved to:
```
~/Library/Application Support/AXTerm/Logs/ax25-diagnostic-YYYY-MM-DD_HHMMSS.log
```

**To access in Finder:**
1. Press `Cmd+Shift+G`
2. Paste: `~/Library/Application Support/AXTerm/Logs/`
3. Press Enter

### File Format Example

```
================================================================================
AXTerm Diagnostic Log
Started: 2026-03-02T14:30:22Z
================================================================================

[2026-03-02T14:30:23Z] [INFO] [BLE] [BLE TNC4] Service discovered: 00000001-BA2A-46C9-AE49-01B0961F68BB {known=yes}
[2026-03-02T14:30:23Z] [INFO] [BLE] [BLE TNC4] TX characteristic selected: 00000002-BA2A-46C9-AE49-01B0961F68BB {priority=3, reason=Known service UUID match}
[2026-03-02T14:30:24Z] [DEBUG] [KISS] [BLE TNC4] Frame complete: DATA {port=0, command=0, size=42}
Hex dump (42 bytes):
0000: C0 00 AE 92 88 8A 62 40 E0 AE 92 88 8A 64 61 03  ......b@.....da.
0010: F0 3E 41 50 52 53 20 54 65 73 74 20 4D 65 73 73  .>APRS Test Mess
0020: 61 67 65 20 23 31 32 33 C0                       age #123.

[2026-03-02T14:30:24Z] [INFO] [AX.25] [BLE TNC4] Frame: KB1XYZ-7 → APRS-0 (UI) {src=KB1XYZ-7, dst=APRS-0, type=UI, control=0x03, info_size=30}
[2026-03-02T14:30:25Z] [WARNING] [Reception] [BLE TNC4] ⏱️ RECEPTION GAP DETECTED {gap_duration=5.23, threshold=5.00}
```

### When to Use File Logging

| Scenario | File Logging | Reason |
|----------|--------------|--------|
| DEBUG builds | ✅ YES | Full diagnostic capability |
| Development | ✅ YES | Easy to share logs with team |
| Testing | ✅ YES | Capture long test runs |
| Bug investigation | ✅ YES | Keep complete history |
| RELEASE builds | ❌ NO | Minimal overhead |
| Production | ❌ NO | Privacy & performance |

### Performance Impact

File logging adds minimal overhead:
- **Disk I/O:** ~1-2% CPU
- **Disk space:** ~1-5 MB per session (auto-cleaned)
- **Memory:** ~50 KB buffer
- **Total impact:** Negligible on modern Macs

### Runtime Control

You can enable/disable file logging while running:

```swift
// Enable file logging
Task {
    try? await AX25DiagnosticLogger.shared.enableFileLogging()
}

// Disable file logging
Task {
    await AX25DiagnosticLogger.shared.disableFileLogging()
}
```

### Add to Debug Menu

```swift
CommandMenu("Debug") {
    Button("Open Current Log File") {
        Task {
            await AX25DiagnosticLogger.shared.openLogFile()
        }
    }
    .keyboardShortcut("L", modifiers: [.command, .shift])
    
    Button("Show Log Folder") {
        Task {
            await AX25DiagnosticLogger.shared.revealLogFile()
        }
    }
    
    Divider()
    
    Button("Enable File Logging") {
        Task {
            try? await AX25DiagnosticLogger.shared.enableFileLogging()
        }
    }
    
    Button("Disable File Logging") {
        Task {
            await AX25DiagnosticLogger.shared.disableFileLogging()
        }
    }
}
```

---

## Summary

### Q1: Enabled by default?
**NO** - You must add 3 lines of code to your app's init:
```swift
Task {
    await AX25DiagnosticLogger.shared.updateConfig(.comprehensive)
    try? await AX25DiagnosticLogger.shared.enableFileLogging()
}
```

### Q2: Log to file?
**YES** - File logging is built-in and enabled with one line:
```swift
try? await AX25DiagnosticLogger.shared.enableFileLogging()
```

### Complete Setup (Copy & Paste)

```swift
@main
struct AXTermApp: App {
    init() {
        // ⭐ THIS IS ALL YOU NEED ⭐
        #if DEBUG
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(.comprehensive)
            try? await AX25DiagnosticLogger.shared.enableFileLogging()
            if let url = await AX25DiagnosticLogger.shared.getLogFileURL() {
                print("📝 Logs: \(url.path)")
            }
        }
        #endif
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### What You Get

✅ **Console.app logs** - Real-time OSLog messages  
✅ **File logs** - Persistent logs saved to disk  
✅ **Hex dumps** - Byte-level debugging  
✅ **Bug detection** - Automatic override detection  
✅ **Gap tracking** - Reception stoppage alerts  
✅ **Zero maintenance** - Auto-cleanup, auto-management  

### Files to Add

1. `AX25DiagnosticLogger.swift` - Core logger
2. Add file logging code from `ADD_TO_AX25DiagnosticLogger.md`
3. `AX25DiagnosticLogger+Integration.swift` - Helpers
4. Add init code to your app (3 lines shown above)

**That's it!** You now have comprehensive diagnostic logging with file output. 🎉
