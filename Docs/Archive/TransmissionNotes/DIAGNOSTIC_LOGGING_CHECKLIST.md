# Diagnostic Logging Integration Checklist

Quick reference for adding comprehensive diagnostic logging to AXTerm.

## ✅ Setup (One-time)

- [x] `AX25DiagnosticLogger.swift` - Core logging system
- [x] `AX25DiagnosticLogger+Integration.swift` - Helper extensions
- [x] `KISSLinkBLE+Diagnostics.swift` - Integration examples
- [x] `DIAGNOSTIC_LOGGING_GUIDE.md` - Complete documentation

## 📝 Integration Steps

### 1. Enable at App Startup

In your `@main` app struct or `AppDelegate`:

```swift
init() {
    #if DEBUG
    AX25DiagnosticLogger.enableDebugMode()
    #else
    AX25DiagnosticLogger.enableStandardMode()
    #endif
}
```

### 2. Add to KISSLinkBLE.swift

#### A. Service Discovery
Location: `peripheral(_:didDiscoverServices:)`
```swift
for service in services {
    BLEDiagnostic.serviceDiscovered(endpoint: endpointDescription, service: service)
}
```

#### B. Characteristic Discovery
Location: `peripheral(_:didDiscoverCharacteristicsFor:error:)`
```swift
for characteristic in characteristics {
    BLEDiagnostic.characteristicDiscovered(
        endpoint: endpointDescription,
        service: service,
        characteristic: characteristic
    )
}
```

#### C. Characteristic Selection (CRITICAL - Catches the Bug!)
Location: `selectBestCharacteristics()` - BEFORE assigning to txCharacteristic/rxCharacteristic
```swift
// Before: txCharacteristic = char
if let existing = txCharacteristic {
    BLEDiagnostic.characteristicOverride(
        endpoint: endpointDescription,
        role: "TX",
        oldCharacteristic: existing,
        newCharacteristic: char,
        reason: "Override during selection"
    )
} else {
    BLEDiagnostic.characteristicSelected(
        endpoint: endpointDescription,
        role: "TX",
        characteristic: char,
        priority: priority,
        reason: "Initial selection"
    )
}
txCharacteristic = char
```

#### D. Subscription Changes
Location: `peripheral(_:didUpdateNotificationStateFor:error:)`
```swift
BLEDiagnostic.subscriptionChanged(
    endpoint: endpointDescription,
    characteristic: characteristic,
    enabled: characteristic.isNotifying,
    error: error
)
```

#### E. Data Filtering (CRITICAL - Shows the Bug's Effect!)
Location: `peripheral(_:didUpdateValueFor:error:)` - when filtering wrong characteristic
```swift
if let currentRx, characteristic.uuid != currentRx.uuid {
    BLEDiagnostic.dataFiltered(
        endpoint: endpointDescription,
        receivedFrom: characteristic,
        expected: currentRx,
        data: data
    )
    return
}
```

### 3. Add to KISS Frame Processing

Location: Where you decode KISS frames
```swift
// When frame is complete
if let (port, command) = data.kissPortAndCommand {
    KISSDiagnostic.frameComplete(
        endpoint: endpointDescription,
        frame: data,
        port: port,
        command: command
    )
}

// When there's an error
KISSDiagnostic.frameError(
    endpoint: endpointDescription,
    reason: "Invalid escape sequence",
    partialData: data
)
```

### 4. Add to AX.25 Frame Processing

Location: Where you parse AX.25 frames
```swift
AX25Diagnostic.frameReceived(
    endpoint: linkEndpoint,
    source: sourceCallsign,
    destination: destCallsign,
    control: controlByte,
    info: infoData,
    rawFrame: frameData
)

// For errors
AX25Diagnostic.parseError(
    endpoint: linkEndpoint,
    reason: error.localizedDescription,
    rawData: rawData
)
```

## 🔍 Verification

After integration, test by connecting to TNC4 and checking Console.app:

### Should See (Good):
```
[BLE] Service discovered: 00000001-BA2A-46C9-AE49-01B0961F68BB {known=yes}
[BLE] Selected TX (priority 3): 00000002-... {reason=Known service UUID match}
[BLE] Selected RX (priority 3): 00000003-... {reason=Known service UUID match}
[KISS] Frame complete: DATA {port=0, command=0, size=45}
[AX.25] Frame: KB1XYZ → CQ (UI)
```

### Should NOT See (Bug):
```
⚠️ TX CHARACTERISTIC OVERRIDE (BUG RISK!)
🚫 DATA FILTERED - Wrong characteristic!
⏱️ RECEPTION GAP DETECTED
```

## 🐛 Debugging Workflows

### Problem: Packets Stop
1. Enable debug mode: `AX25DiagnosticLogger.enableDebugMode()`
2. Look for: Override → Filtering → Gap sequence
3. Fix: Ensure characteristics selected only once

### Problem: Garbled Data
1. Enable KISS logging in config
2. Look for: Frame decode errors, hex dumps
3. Check: MTU settings, fragmentation

### Problem: Connection Issues
1. Enable BLE characteristic logging
2. Look for: Service discovery, subscription failures
3. Check: Characteristic selection priorities

## 📊 Performance

| Mode | Overhead | When to Use |
|------|----------|-------------|
| Minimal | <1% | Production release |
| Standard | ~2% | Default, ongoing monitoring |
| Debug | ~5% | Active debugging only |

## 🎯 Key Benefits

✅ **Automatically detects** the characteristic override bug  
✅ **Tracks reception gaps** to identify silent failures  
✅ **Provides hex dumps** for byte-level debugging  
✅ **Categorizes events** for easy log filtering  
✅ **Includes timing data** for performance analysis  
✅ **Configurable verbosity** for different scenarios  

## 📖 Full Documentation

See `DIAGNOSTIC_LOGGING_GUIDE.md` for:
- Complete API reference
- Advanced configuration
- Troubleshooting workflows
- Log interpretation guide
- Integration examples

## ⚡ Quick Commands

```swift
// Enable debug mode
AX25DiagnosticLogger.enableDebugMode()

// Back to standard
AX25DiagnosticLogger.enableStandardMode()

// View reception summary
Task {
    await AX25DiagnosticLogger.shared.logReceptionSummary(endpoint: "BLE TNC4")
}

// Custom config
Task {
    var config = AX25DiagnosticConfig.standard
    config.detectReceptionGaps = true
    config.receptionGapThreshold = 3.0
    await AX25DiagnosticLogger.shared.updateConfig(config)
}
```

## 🎓 Summary

This logging system makes debugging AX.25/BLE issues **dramatically easier**. The key integration points are:

1. **Characteristic selection** - Catches the override bug
2. **Data filtering** - Shows the bug's effects
3. **KISS frames** - Byte-level debugging
4. **AX.25 frames** - Protocol analysis

With proper logging in place, future issues will be **easy to diagnose** from log output alone.
