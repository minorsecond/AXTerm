# AX.25 Diagnostic Logging Guide

## Overview

The `AX25DiagnosticLogger` provides comprehensive, structured logging for debugging BLE, KISS, and AX.25 issues in AXTerm. This guide shows you how to use it effectively.

## Quick Start

### 1. Enable Diagnostic Logging

Add this at app startup (e.g., in `AppDelegate` or your main `@main` struct):

```swift
import SwiftUI

@main
struct AXTermApp: App {
    init() {
        // Enable comprehensive debugging during development
        #if DEBUG
        AX25DiagnosticLogger.enableDebugMode()
        #else
        AX25DiagnosticLogger.enableStandardMode()
        #endif
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### 2. View Logs

**In Console.app (macOS):**
1. Open Console.app
2. Select your device/simulator
3. Filter by subsystem: `com.rosswardrup.AXTerm`
4. Filter by category: `AX25Diagnostics`

**In Xcode:**
- Logs appear directly in the debug console with full formatting

## Configuration Levels

### Comprehensive (Debug Mode)
```swift
AX25DiagnosticLogger.enableDebugMode()
```

**Logs everything:**
- Every byte-level event
- Full hex dumps (no size limit)
- All KISS frame boundaries
- All BLE events
- Performance timing
- Reception gap detection (3s threshold)

**Best for:** Deep debugging, investigating packet loss, analyzing new TNC behavior

### Standard (Recommended)
```swift
AX25DiagnosticLogger.enableStandardMode()
```

**Logs key events:**
- BLE characteristic selection
- KISS frames (complete frames only)
- AX.25 frame summaries
- Errors and warnings
- Reception gaps (5s threshold)
- Hex dumps (limited to 128 bytes)

**Best for:** Production use, routine monitoring

### Minimal (Performance)
```swift
AX25DiagnosticLogger.enableMinimalMode()
```

**Logs only errors:**
- Critical failures
- No hex dumps
- No debug information

**Best for:** Release builds, maximum performance

### Custom Configuration
```swift
Task {
    var config = AX25DiagnosticConfig.standard
    config.detectReceptionGaps = true
    config.receptionGapThreshold = 10.0  // 10 second threshold
    config.logBLECharacteristics = true
    config.maxHexDumpBytes = 64
    await AX25DiagnosticLogger.shared.updateConfig(config)
}
```

## Integration Examples

### BLE Characteristic Selection

In `KISSLinkBLE.swift`, when selecting characteristics:

```swift
// Log the selection
BLEDiagnostic.characteristicSelected(
    endpoint: endpointDescription,
    role: "TX",
    characteristic: txChar,
    priority: 3,
    reason: "Known service UUID match (Mobilinkd)"
)

// If overriding (THIS IS THE BUG!)
if let existingTX = txCharacteristic {
    BLEDiagnostic.characteristicOverride(
        endpoint: endpointDescription,
        role: "TX",
        oldCharacteristic: existingTX,
        newCharacteristic: newTXChar,
        reason: "Second service discovery"
    )
}
```

### KISS Frame Processing

When receiving KISS data:

```swift
func processKISSData(_ data: Data) {
    // Log frame boundaries
    if data.startsWithKISSFend {
        KISSDiagnostic.frameBoundary(
            endpoint: endpointDescription,
            isStart: true,
            portByte: data.count > 1 ? data[1] : nil
        )
    }
    
    // ... decode frame ...
    
    if let (port, command) = data.kissPortAndCommand {
        KISSDiagnostic.frameComplete(
            endpoint: endpointDescription,
            frame: data,
            port: port,
            command: command
        )
    }
    
    // Log errors
    if decodeError {
        KISSDiagnostic.frameError(
            endpoint: endpointDescription,
            reason: "Invalid escape sequence",
            partialData: data
        )
    }
}
```

### AX.25 Frame Processing

When parsing AX.25 frames:

```swift
func parseAX25Frame(_ frame: Data) {
    do {
        let source = try extractSourceCallsign(frame)
        let dest = try extractDestCallsign(frame)
        let control = frame[14]
        let info = frame.count > 15 ? frame[15...] : nil
        
        AX25Diagnostic.frameReceived(
            endpoint: linkEndpoint,
            source: source,
            destination: dest,
            control: control,
            info: info,
            rawFrame: frame
        )
    } catch {
        AX25Diagnostic.parseError(
            endpoint: linkEndpoint,
            reason: error.localizedDescription,
            rawData: frame
        )
    }
}
```

### BLE Data Filtering

In `didUpdateValueFor` when filtering wrong characteristic:

```swift
func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let data = characteristic.value else { return }
    
    if characteristic.uuid != rxCharacteristic?.uuid {
        // Log the filtered data
        if let expectedRX = rxCharacteristic {
            BLEDiagnostic.dataFiltered(
                endpoint: endpointDescription,
                receivedFrom: characteristic,
                expected: expectedRX,
                data: data
            )
        }
        return
    }
    
    // Process normal data...
}
```

## Reading the Logs

### BLE Characteristic Override Bug

**What to look for:**
```
[BLE] [BLE TNC4] ⚠️ TX CHARACTERISTIC OVERRIDE (BUG RISK!) {old=49535343-..., new=00000002-..., reason=Second service discovery}
```

**This means:** The original bug is happening! Characteristics are being reassigned after initial selection.

### Reception Stoppage

**What to look for:**
```
[Reception] [BLE TNC4] ⏱️ RECEPTION GAP DETECTED {gap_duration=12.45, threshold=5.00}
[BLE] [BLE TNC4] 🚫 DATA FILTERED - Wrong characteristic! {received_from=49535343-..., expected=00000003-..., bytes_discarded=42}
```

**This means:** Packets are arriving but being filtered because the wrong characteristic is receiving data.

### Normal Operation

**What you should see:**
```
[BLE] [BLE TNC4] Service discovered: 00000001-BA2A-46C9-AE49-01B0961F68BB {known=yes}
[BLE] [BLE TNC4] Selected TX (priority 3): 00000002-BA2A-46C9-AE49-01B0961F68BB {service=00000001-..., reason=Known service UUID match}
[BLE] [BLE TNC4] Selected RX (priority 3): 00000003-BA2A-46C9-AE49-01B0961F68BB {service=00000001-..., reason=Known service UUID match}
[KISS] [BLE TNC4] Frame complete: DATA {port=0, command=0, size=45}
[AX.25] [BLE TNC4] Frame: KB1XYZ-7 → CQ-0 (UI) {src=KB1XYZ-7, dst=CQ-0, type=UI, control=0x03, info_size=30}
[Reception] [BLE TNC4] Packet #142 {timestamp=45.234, bytes=45, total_bytes=6234}
```

### KISS Frame Issues

**What to look for:**
```
[KISS] [BLE TNC4] Frame decode error: Truncated frame
Hex dump (12 bytes):
0000: C0 00 AE 92 88 8A 62 40 E0 AE 92 88              ......b@....
```

**This means:** Incomplete KISS frame received. Check MTU settings or packet fragmentation.

### AX.25 Parse Errors

**What to look for:**
```
[AX.25] [BLE TNC4] Parse error: Invalid callsign encoding
Hex dump (15 bytes):
0000: AE 92 88 8A 62 40 E0 AE 92 88 8A 64 61 03 F0     ....b@.....da..
```

**This means:** Malformed AX.25 header. Check for corruption or non-standard frames.

## Troubleshooting Workflows

### Problem: Packets stop after a few minutes

1. Enable comprehensive logging:
   ```swift
   AX25DiagnosticLogger.enableDebugMode()
   ```

2. Look for sequence:
   - Initial characteristic selection (should see priority 3 for known service)
   - Look for "CHARACTERISTIC OVERRIDE" warnings
   - Look for "RECEPTION GAP DETECTED"
   - Look for "DATA FILTERED" errors

3. If you see override → filtering → gap, that's the characteristic override bug

### Problem: Garbled or missing data

1. Enable KISS framing logs:
   ```swift
   Task {
       var config = AX25DiagnosticConfig.standard
       config.logKISSFraming = true
       config.enableHexDumps = true
       await AX25DiagnosticLogger.shared.updateConfig(config)
   }
   ```

2. Look for:
   - Frame decode errors
   - Truncated frames
   - Invalid escape sequences
   - Check hex dumps for corruption

### Problem: Connection drops

1. Enable BLE characteristic logging:
   ```swift
   Task {
       var config = AX25DiagnosticConfig.standard
       config.logBLECharacteristics = true
       await AX25DiagnosticLogger.shared.updateConfig(config)
   }
   ```

2. Look for:
   - Service discovery sequence
   - Characteristic selection
   - Subscription failures
   - Unexpected characteristic changes

### Problem: Performance issues

1. Enable performance timing:
   ```swift
   Task {
       var config = AX25DiagnosticConfig.standard
       config.enablePerformanceTiming = true
       await AX25DiagnosticLogger.shared.updateConfig(config)
   }
   ```

2. Wrap operations:
   ```swift
   await AX25DiagnosticLogger.shared.startTiming("parse_ax25_frame")
   // ... do work ...
   await AX25DiagnosticLogger.shared.endTiming("parse_ax25_frame", endpoint: endpoint)
   ```

3. Look for slow operations in logs

## Advanced Usage

### Runtime Configuration Changes

```swift
// In a debug menu or settings view
Button("Enable Debug Logging") {
    AX25DiagnosticLogger.enableDebugMode()
}

Button("View Reception Summary") {
    Task {
        await AX25DiagnosticLogger.shared.logReceptionSummary(
            endpoint: "BLE TNC4"
        )
    }
}
```

### Custom Log Messages

```swift
Task {
    await AX25DiagnosticLogger.shared.logInfo(
        "Custom diagnostic event",
        endpoint: endpointDescription,
        metadata: [
            "event_type": "reconnect",
            "attempt": "3",
            "reason": "timeout"
        ]
    )
}
```

### Conditional Logging

```swift
#if DEBUG
let logLevel = AX25DiagnosticConfig.comprehensive
#else
let logLevel = AX25DiagnosticConfig.standard
#endif

Task {
    await AX25DiagnosticLogger.shared.updateConfig(logLevel)
}
```

## Best Practices

1. **Enable comprehensive logging during bug investigation**, but revert to standard for normal use
2. **Include endpoint description** in all log calls for multi-connection scenarios
3. **Use the convenience helpers** (`BLEDiagnostic`, `KISSDiagnostic`, `AX25Diagnostic`) rather than calling the logger directly
4. **Check logs early** when investigating issues - the answer is usually there
5. **Share logs** when reporting bugs - hex dumps and timestamps are invaluable
6. **Don't leave debug mode on** in production builds - it impacts performance

## Performance Impact

| Level | CPU Impact | Log Volume | Use Case |
|-------|-----------|------------|----------|
| Minimal | <1% | Very Low | Production |
| Standard | ~2% | Moderate | Default |
| Comprehensive | ~5% | Very High | Debug Only |

## Export Logs for Bug Reports

1. In Console.app, select the log messages
2. Right-click → Export...
3. Save as text file
4. Attach to bug report with description

## Summary

The diagnostic logger makes debugging AX.25/BLE issues dramatically easier by:

- **Detecting the characteristic override bug** automatically
- **Tracking reception gaps** to identify silent failures
- **Providing hex dumps** for byte-level debugging
- **Categorizing events** for easy filtering
- **Including timestamps** for timing analysis
- **Being configurable** for different use cases

When investigating issues, **enable comprehensive logging first**, then analyze the structured output to pinpoint the problem.
