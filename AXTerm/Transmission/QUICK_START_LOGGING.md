# Quick Start: Enabling Diagnostic Logging

## ⚠️ Important: Not Enabled by Default!

The diagnostic logging system is **NOT automatically enabled**. You must add initialization code to your app.

## Step 1: Copy the Diagnostic Logger Files

Make sure these files are in your project:
- ✅ `AX25DiagnosticLogger.swift`
- ✅ `AX25DiagnosticLogger+Integration.swift`
- ✅ `AX25DiagnosticLogger+FileLogging.swift`
- ✅ `KISSLinkBLE+Diagnostics.swift`

## Step 2: Enable at App Startup

### For SwiftUI Apps

Add this to your `@main` app struct:

```swift
import SwiftUI

@main
struct AXTermApp: App {
    init() {
        // ⭐ THIS IS REQUIRED - Enables diagnostic logging
        setupDiagnosticLogging()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
    
    private func setupDiagnosticLogging() {
        #if DEBUG
        // Debug builds: Comprehensive logging + file logging
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(.comprehensive)
            try? await AX25DiagnosticLogger.shared.enableFileLogging()
            print("🔍 Comprehensive diagnostic logging enabled")
            
            if let logURL = await AX25DiagnosticLogger.shared.getLogFileURL() {
                print("📝 Log file: \(logURL.path)")
            }
        }
        #else
        // Release builds: Standard logging (OSLog only, no file)
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(.standard)
            print("📊 Standard diagnostic logging enabled")
        }
        #endif
    }
}
```

### For AppKit Apps

Add this to your `AppDelegate`:

```swift
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupDiagnosticLogging()
    }
    
    private func setupDiagnosticLogging() {
        #if DEBUG
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(.comprehensive)
            try? await AX25DiagnosticLogger.shared.enableFileLogging()
            NSLog("🔍 Comprehensive diagnostic logging enabled")
            
            if let logURL = await AX25DiagnosticLogger.shared.getLogFileURL() {
                NSLog("📝 Log file: \(logURL.path)")
            }
        }
        #else
        Task {
            await AX25DiagnosticLogger.shared.updateConfig(.standard)
            NSLog("📊 Standard diagnostic logging enabled")
        }
        #endif
    }
}
```

## Step 3: Verify It's Working

### Check Console Output

When you run the app in DEBUG mode, you should see:
```
🔍 Comprehensive diagnostic logging enabled
📝 Log file: /Users/yourname/Library/Application Support/AXTerm/Logs/ax25-diagnostic-2026-03-02_101523.log
```

### Check Console.app

1. Open Console.app
2. Filter by: `subsystem:com.rosswardrup.AXTerm`
3. Category: `AX25Diagnostics`
4. You should see log messages when BLE connects

### Check Log File

Log files are written to:
```
~/Library/Application Support/AXTerm/Logs/
```

To access in Finder:
1. Press `Cmd+Shift+G`
2. Paste: `~/Library/Application Support/AXTerm/Logs/`
3. Press Enter

You should see files like: `ax25-diagnostic-2026-03-02_101523.log`

## What Gets Logged

### In DEBUG Builds
✅ **OSLog (Console.app)**: All messages with categorization  
✅ **File logging**: Complete logs with hex dumps saved to disk  
✅ **Comprehensive mode**: Every BLE, KISS, AX.25 event  
✅ **Hex dumps**: Full byte-level data  
✅ **Performance timing**: Operation durations  

### In RELEASE Builds
✅ **OSLog (Console.app)**: Key events and errors only  
❌ **No file logging**: Saves disk space and I/O  
❌ **No verbose logs**: Minimal overhead  

## File Logging Features

### Automatic Management
- ✅ Creates new log file each session
- ✅ Keeps last 10 log files
- ✅ Auto-deletes older logs
- ✅ Includes timestamps
- ✅ Includes hex dumps

### Log File Format
```
================================================================================
AXTerm Diagnostic Log
Started: 2026-03-02T10:15:23Z
================================================================================

[2026-03-02T10:15:24Z] [INFO] [BLE] [BLE TNC4] Service discovered: 00000001-... {known=yes}
[2026-03-02T10:15:24Z] [INFO] [BLE] [BLE TNC4] TX characteristic selected: 00000002-... {priority=3}
[2026-03-02T10:15:25Z] [DEBUG] [KISS] [BLE TNC4] Frame complete: DATA {port=0, size=42}
Hex dump (42 bytes):
0000: C0 00 AE 92 88 8A 62 40 E0 AE 92 88 8A 64 61 03  ......b@.....da.
0010: F0 3E 41 50 52 53 20 54 65 73 74 20 4D 65 73 73  .>APRS Test Mess
0020: 61 67 65 20 23 31 32 33 C0                       age #123.
```

## Accessing Logs Programmatically

### Get Log File URL
```swift
Task {
    if let url = await AX25DiagnosticLogger.shared.getLogFileURL() {
        print("Current log file: \(url.path)")
    }
}
```

### Open Log in Editor
```swift
Task {
    await AX25DiagnosticLogger.shared.openLogFile()
}
```

### Reveal in Finder
```swift
Task {
    await AX25DiagnosticLogger.shared.revealLogFile()
}
```

### Add to Debug Menu
```swift
CommandMenu("Debug") {
    Button("Open Log File") {
        Task {
            await AX25DiagnosticLogger.shared.openLogFile()
        }
    }
    .keyboardShortcut("L", modifiers: [.command, .shift])
    
    Button("Reveal Log in Finder") {
        Task {
            await AX25DiagnosticLogger.shared.revealLogFile()
        }
    }
}
```

## Runtime Configuration

You can change logging settings while the app is running:

### Enable Comprehensive Logging
```swift
Task {
    await AX25DiagnosticLogger.shared.updateConfig(.comprehensive)
}
```

### Enable File Logging
```swift
Task {
    try? await AX25DiagnosticLogger.shared.enableFileLogging()
}
```

### Disable File Logging
```swift
Task {
    await AX25DiagnosticLogger.shared.disableFileLogging()
}
```

## Troubleshooting

### Problem: No logs appearing

**Check:**
1. Did you call `setupDiagnosticLogging()` in your app's init?
2. Is the code actually running? (Add a print statement to verify)
3. Is Console.app filtering correctly? (Check subsystem and category)

### Problem: No log file created

**Check:**
1. Are you in a DEBUG build?
2. Did you call `enableFileLogging()`?
3. Check file permissions for Application Support directory
4. Check console for error messages

### Problem: Can't find log files

**Location:**
```bash
# Open in Terminal:
open ~/Library/Application\ Support/AXTerm/Logs/

# Or list files:
ls -lh ~/Library/Application\ Support/AXTerm/Logs/
```

### Problem: Log file too large

**Automatic cleanup:**
- Only last 10 files kept
- Old files auto-deleted
- Each session creates new file

**Manual cleanup:**
```bash
# Delete all logs:
rm -rf ~/Library/Application\ Support/AXTerm/Logs/*.log

# Delete logs older than 7 days:
find ~/Library/Application\ Support/AXTerm/Logs/ -name "*.log" -mtime +7 -delete
```

## Performance Impact

| Mode | OSLog | File I/O | Total Overhead | Recommended For |
|------|-------|----------|----------------|-----------------|
| Minimal | <1% | None | <1% | Production |
| Standard | ~1-2% | None | ~1-2% | Default |
| Comprehensive | ~3-4% | ~1-2% | ~5% | Debug only |

## Summary

**Required Steps:**
1. ✅ Add diagnostic logger files to project
2. ✅ Add initialization code to app startup
3. ✅ Run app and verify logging works
4. ✅ Check both Console.app and log files

**Default Behavior:**
- DEBUG builds: Comprehensive + file logging
- RELEASE builds: Standard, no file

**Access Logs:**
- Console.app: `subsystem:com.rosswardrup.AXTerm`
- Files: `~/Library/Application Support/AXTerm/Logs/`

Now you're ready to debug any AX.25, BLE, or KISS issues! 🎉
