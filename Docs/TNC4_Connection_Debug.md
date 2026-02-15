# TNC4 Connection Debug — February 2026

## Issue Summary

Two related problems with Mobilinkd TNC4 connectivity:

1. **USB serial connection fails on startup** — device not found, repeated reconnect attempts
2. **Packets only received while settings panel is open** — closing settings kills RX

Both USB and BLE transports are affected by issue #2.

---

## Root Cause Analysis

### Problem 1: USB Serial Connection Failure

**Symptom:** Log shows `Link state: connecting → failed` followed by repeated reconnect attempts. The serial device path stored in settings doesn't match an existing `/dev/cu.*` entry.

**Likely cause:** The USB serial device path (e.g., `/dev/cu.usbmodemXXXX`) changes when the TNC4 is unplugged/replugged or macOS re-enumerates USB devices. The stored `settings.serialDevicePath` becomes stale.

**Log evidence:**
```
connection: Connecting to serial:
Link info:  Opening serial port... [3C8738]
Link state:  connecting → failed
connection: Connection failed:
```

The path after "Connecting to serial:" is empty or invalid.

### Problem 2: RX Only Works While Settings Panel Is Open

**This is the critical bug.** The chain of events:

#### What happens on app startup (normal flow):

1. `PacketEngine.init()` calls `connectUsingSettings()`
2. `connectSerial()` creates `KISSLinkSerial`, calls `open()`
3. `sendKISSInit()` sends KISS params + Mobilinkd config
4. **Lines 688-718 of KISSLinkSerial.swift:** After a 2.5s delay, sends `POLL_INPUT_LEVEL` (stops demod), then after 2s sends `RESET` (restarts demod)
5. Demodulator should be running after ~4.5s

#### What happens when settings panel opens:

1. `ConnectionSettingsView.onAppear` → `suspendAutoReconnect(true)`
2. Sets `PacketEngine.isConnectionLogicSuspended = true`
3. This **prevents** settings change observers from triggering `connectUsingSettings()`
4. The existing link stays alive and stable

#### What happens when user clicks "Measure & Auto-Adjust Input Levels":

1. `triggerAutoGain()` → `PacketEngine.sendAdjustInputLevels()`
2. Sends `ADJUST_INPUT_LEVELS` (0x2B) — **stops demodulator**
3. After 5s delay, sends `RESET` (0x0B) — **restarts demodulator**
4. Demodulator is now running, packets are received

#### What happens when settings panel closes:

1. `ConnectionSettingsView.onDisappear` → `suspendAutoReconnect(false)`
2. `isConnectionLogicSuspended.didSet` fires → calls `connectUsingSettings()`
3. **For BLE:** `connectBLE()` calls `disconnect(reason:)` which **destroys the link entirely**, then creates a new one
4. **For serial:** `connectSerial()` checks if same device path — if so, calls `updateConfig()` which may close/reopen
5. Either way, a new KISS init sequence starts, including the POLL→RESET dance
6. **But the link may get destroyed AGAIN** if settings observers fire (debounced 500ms)

**The key insight:** Every time `connectUsingSettings()` runs, for BLE it unconditionally tears down the connection. For serial, even `updateConfig` may cause a close/reopen cycle. The POLL→RESET demod restart sequence fires ~4.5s after connection, but if the connection gets torn down again within that window, the demod never actually restarts.

#### Why it works with settings open:

- Suspension prevents `connectUsingSettings()` from being called
- The link stays stable
- The manual "Auto-Adjust" sends ADJUST_INPUT_LEVELS → RESET
- This properly restarts the demodulator
- Packets flow

#### Why it stops when settings closes:

- `connectUsingSettings()` fires immediately on panel close
- This may tear down and rebuild the link
- Settings observers may fire additional `connectUsingSettings()` calls (500ms debounce)
- The POLL→RESET sequence from the first init gets cancelled when the link is torn down
- The demodulator ends up stopped because POLL ran but RESET didn't

---

## BLE-Specific Issue

`connectBLE()` **always** calls `disconnect()` first (line 397), unlike `connectSerial()` which has optimization for same-device-path. This means every settings-panel-close causes a full BLE reconnection cycle (several seconds of BLE discovery + service discovery + characteristic subscription), making the problem even worse for BLE.

---

## Fix Strategy

### Fix 1: Don't reconnect on settings close if nothing changed

The `isConnectionLogicSuspended.didSet` unconditionally calls `connectUsingSettings()`. It should only reconnect if settings actually changed during the suspension period.

### Fix 2: BLE connectBLE() should reuse existing link if config matches

Like `connectSerial()` checks for same device path, `connectBLE()` should check if the existing BLE link has the same peripheral UUID and skip full teardown.

### Fix 3: KISS init POLL→RESET must be resilient

The 2.5s + 2.0s delayed POLL→RESET sequence in `sendKISSInit()` should be more robust — perhaps use a single method that ensures the RESET always follows the POLL even if the link gets momentarily disrupted.

### Fix 4: USB device path auto-detection

On startup, if the saved serial device path doesn't exist, scan `/dev/cu.*` for matching Mobilinkd device names (e.g., containing "usbmodem" or TNC4 identifier).

---

## Test Scripts

Located in project root:
- `diagnose_audio_levels.swift` — polls audio input levels repeatedly
- `test_serial_cmd.swift` — tests USB serial open + KISS EXIT
- `test_serial_rx.py` — Python script to open TNC4 serial, send RESET + battery poll, listen for data
- `test_termios` — compiled binary for testing serial termios config

---

## Key Code Paths

| Component | File | Lines | Purpose |
|-----------|------|-------|---------|
| Settings panel lifecycle | `ConnectionSettingsView.swift` | 50-57 | Suspend/resume auto-reconnect |
| Suspend logic | `ConnectionTransportViewModel.swift` | 301-307 | Bridge to PacketEngine |
| Suspension flag | `PacketEngine.swift` | 1417-1429 | `isConnectionLogicSuspended` |
| Settings observers | `PacketEngine.swift` | 1431-1498 | React to settings changes |
| Connect dispatch | `PacketEngine.swift` | 295-337 | `connectUsingSettings()` |
| Serial connect | `PacketEngine.swift` | 365-393 | Same-path optimization |
| BLE connect | `PacketEngine.swift` | 396-408 | **Always tears down** |
| Disconnect | `PacketEngine.swift` | 417-435 | Destroys link |
| Serial KISS init | `KISSLinkSerial.swift` | 594-718 | Config + POLL + RESET |
| BLE KISS init | `KISSLinkBLE.swift` | 502-568 | Config + POLL + RESET |
| Auto-adjust | `PacketEngine.swift` | 575-587 | ADJUST_INPUT_LEVELS + RESET |
| Mobilinkd frames | `MobilinkdTNC.swift` | 83-93 | Frame generators |

---

## Firmware Reference

From `tnc4-firmware/TNC/KissHardware.hpp`:
- `POLL_INPUT_LEVEL (0x04)` — **STOPS DEMODULATOR**. Returns Vpp/Vavg/Vmin/Vmax.
- `ADJUST_INPUT_LEVELS (0x2B)` — **STOPS DEMODULATOR** for ~5s during auto-AGC.
- `RESET (0x0B)` — Restarts demodulator. Must be sent after either of the above.
- `GET_BATTERY_LEVEL (0x06)` — Safe to poll, does NOT affect demodulator.

---

## Status

- [ ] Fix 1: Guard `connectUsingSettings()` on settings-close — only reconnect if config changed
- [ ] Fix 2: BLE link reuse for same peripheral UUID
- [ ] Fix 3: Robust POLL→RESET sequence
- [ ] Fix 4: USB device path auto-detection on startup
