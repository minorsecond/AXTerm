# AXDP Reassembly Fix Verification

## Problem
When a long AXDP chat message was fragmented across multiple I-frames, Station B would:
1. Receive and acknowledge I-frames at AX.25 layer ✅
2. Accumulate fragments in reassembly buffer ✅  
3. **FAIL** to extract complete message ❌
4. Buffer would grow but message never decoded ❌

## Root Cause
The `extractOneAXDPMessage()` function was consuming the **entire buffer** when a message was decoded, instead of only consuming the bytes actually used by that message.

### Before (Buggy):
```swift
private func extractOneAXDPMessage(from buffer: Data) -> (AXDP.Message, Int)? {
    guard let message = AXDP.Message.decode(from: buffer) else { return nil }
    return (message, buffer.count)  // ❌ Consumes entire buffer!
}
```

**Problem**: If buffer contained `[Message1][Message2]`, decoding Message1 would consume the entire buffer, losing Message2.

### After (Fixed):
```swift
private func extractOneAXDPMessage(from buffer: Data) -> (AXDP.Message, Int)? {
    guard let (message, consumedBytes) = AXDP.Message.decode(from: buffer) else { return nil }
    return (message, consumedBytes)  // ✅ Only consumes what was decoded
}
```

## Changes Made

### 1. `AXDP.decodeTLVs()` - Now returns consumed byte count
```swift
// Before:
static func decodeTLVs(from data: Data) -> (tlvs: [TLV], truncated: Bool)

// After:
static func decodeTLVs(from data: Data) -> (tlvs: [TLV], truncated: Bool, consumedBytes: Int)
```

### 2. `AXDP.Message.decode()` - Now returns consumed bytes
```swift
// Before:
static func decode(from data: Data) -> Message?

// After:
static func decode(from data: Data) -> (Message, Int)?  // Returns (message, consumedBytes)
```

### 3. `extractOneAXDPMessage()` - Uses consumed bytes
```swift
// Now correctly removes only consumed bytes:
buf.removeFirst(consumed)  // Instead of buf.removeFirst(buf.count)
```

## Verification

### Unit Tests Updated
- `testReassemblyLongChatMultipleChunks` - Verifies fragmented message reassembly
- `testReassemblyConsumesOnlyDecodedBytes` - Verifies multiple messages in one buffer

### Integration Test Created
- `testFragmentedChatMessageReassembly` - Monitors reassembly buffer state:
  - Tracks buffer accumulation via `onReassemblyEvent` callback
  - Verifies buffer size grows as fragments arrive
  - Verifies complete message extraction
  - Verifies buffer cleared after extraction
  - Verifies chat message delivery

### Test Monitoring Hooks Added
```swift
#if DEBUG
/// Test-only accessor for reassembly buffer state
var testReassemblyBufferState: [String: Int] {
    inboundReassemblyBuffer.mapValues { $0.count }
}

/// Test-only callback for monitoring reassembly events
var onReassemblyEvent: ((String, Int, Bool) -> Void)?  // key, bufferSize, extracted
#endif
```

## Expected Behavior After Fix

1. **Fragment Arrival**: Each I-frame fragment appends to buffer
   - Buffer size: 0 → 128 → 256 → 384 → ... (grows as fragments arrive)

2. **Complete Message Detection**: When buffer contains complete message:
   - `Message.decode()` succeeds and returns `(message, consumedBytes)`
   - `consumedBytes` = exact bytes used (e.g., 1084 bytes for complete message)
   - Buffer: `[Message1(1084 bytes)][Message2...]` → `[Message2...]`

3. **Message Extraction**: Only consumed bytes removed:
   - Before: Buffer had 1084 bytes, consumed 1084 ✅
   - After: Buffer has 2000 bytes, consumed 1084, remaining 916 ✅

4. **Multiple Messages**: If buffer contains multiple messages:
   - Extract Message1 → consume 1084 bytes → remaining buffer has Message2
   - Extract Message2 → consume remaining bytes → buffer empty ✅

## How to Test

### Manual Test (UI Integration)
1. Run `./Scripts/run-ui-tests.sh clean_build`
2. In Station A, send a long chat message (>500 characters)
3. Observe Station B:
   - Should receive and display the complete message ✅
   - Should NOT show "Truncated chat/fileChunk buffer" errors ✅
   - Should NOT retransmit indefinitely ✅

### Automated Test
```bash
# Run integration test (requires KISS relay running)
xcodebuild test -scheme AXTerm \
  -destination 'platform=macOS' \
  -only-testing:AXTermIntegrationTests/AXDPReassemblyIntegrationTests/testFragmentedChatMessageReassembly
```

### Expected Test Output
```
✅ Should have extracted at least one complete message
✅ Should have appended all fragments  
✅ Buffer should have accumulated more than one fragment
✅ Should receive exactly one chat message
✅ Received message should match sent message
✅ Buffer should be empty after successful extraction
```

## Debug Logging

The fix includes debug logging to monitor reassembly:
```
[DEBUG:REASSEMBLY] append | from=TEST-1 chunkLen=128 before=0 after=128
[DEBUG:REASSEMBLY:EXTRACT] ok | bufLen=1084 consumed=1084 type=chat payloadLen=1059
[DEBUG:REASSEMBLY] extracted complete | from=TEST-1 type=chat consumed=1084 payloadLen=1059
```

Key indicator: `consumed=1084` should match the actual message size, not the entire buffer size.

## New Evidence (Feb 6, 2026)

Recent logs show the receiver repeatedly skipping non‑AXDP payloads:
```
[DEBUG:REASSEMBLY] skip non-AXDP | from=TEST-1 size=128 prefix=73207665
[AXDP] Skipping non-AXDP data (no magic header) | from=TEST-1 size=128
```

The payload prefixes decode to plain ASCII (“s ve…”, “rpis…”, etc.), which indicates the sender is sending **plain text** (no `AXT1` magic) even when long messages are fragmented across I‑frames. This means reassembly never starts because no AXDP magic is present at the wire level.

Additional receiver logs (Feb 6, 2026) confirm the payloads are not AXDP even though PID=0xF0:
```
[AXDP] I-frame received at wire | from=TEST-1 hasMagic=false infoLen=128 pid=Optional(240)
[AXDP] I-frame payload delivered to reassembly | hasMagic=false peer=TEST-1
[AXDP] Skipping non-AXDP data (no magic header) | from=TEST-1 prefixAscii=...
```

Conclusion: the receiver is displaying plain‑text lines; the missing paragraphs are not a reassembly bug—AXDP is not being used on the wire for these long messages.

### Actions Taken

To make this unambiguous in future traces, additional debug hooks were added:
1. **UI Send Decision**: Logs whether AXDP was requested, capability status, and whether a fallback to plain text occurred.
2. **Data In Flight**: Logs each I‑frame payload delivered to reassembly with `hasMagic` + prefix hex.
3. **Wire-Level**: Logs each I‑frame received at PacketEngine with `pid`, `hasMagic`, and prefix hex.
4. **Reassembly Resync**: If a buffer is corrupted (magic not at offset 0), the reassembly now logs and resyncs to the first valid magic header instead of discarding everything.

### New Regression Test

Added a regression test that simulates a corrupted buffer with garbage bytes before `AXT1`. The new resync logic must still decode the message:
- `ReassemblyResyncTests.testResyncSkipsLeadingGarbageBeforeMagic`

## New Evidence (Feb 6, 2026) — AXDP Toggle State Contamination

### Symptom
When both sender and receiver toggle AXDP **off**, the first paragraph of a long plain‑text message appears, but subsequent paragraphs do not. If AXDP is toggled **off before any other tests**, the long message displays correctly. This indicates a **state contamination** issue triggered by repeated AXDP on/off transitions, not a wire‑level loss.

### Observations
- The wire payloads show `hasMagic=false` and ASCII prefixes for the long message, confirming **plain text** at the wire level.
- The problem only appears **after** AXDP is toggled on/off during a session.
- Starting with AXDP off avoids the issue, strongly implicating **stale AXDP state** (reassembly flag/buffer) and/or **plain‑text line buffer contamination**.

### Actions Taken (Feb 6, 2026)
1. **Reset per‑peer AXDP state on toggle off**:
   - Clear `peersInAXDPReassembly` and `currentLineBuffers`.
   - Clear SessionCoordinator reassembly buffers for all connected peers.
2. **Reset per‑peer state when peer disables AXDP**:
   - On `peerAxdpDisabled`, clear reassembly and line buffers for that peer.
3. **Extra debug hooks for plain‑text assembly**:
   - Log per‑chunk size, buffer length, and CR/LF counts in `appendToSessionTranscript`.
4. **New regression test**:
   - `testPlainTextAfterAxdpToggleOffStateReset` verifies that stale reassembly state does not suppress plain text after toggling off.

### Expected Outcome
- Repeated AXDP on/off toggles should no longer suppress subsequent plain‑text paragraphs.
- Long plain‑text messages should consistently appear in full on the receiver UI regardless of prior AXDP toggles.

## New Evidence (Feb 6, 2026) — UI Duplicate Grouping Hiding Repeated Paragraphs

### Symptom
- After running `test 1-3 short` and `test 1-2 long`, `test 3 long` (AXDP off) appears to show only the first paragraph in the receiver UI.
- Logs show multiple plain‑text lines are delivered to the console, but the UI only shows the first paragraph for the repeated long message.

### Observations
- `appendToSessionTranscript` logs show multiple flushes with distinct line previews:
  - `Delivering plain text line to console | lineLength=961 preview=test 3 long Lorem ipsum...`
  - `Delivering plain text line to console | lineLength=784 preview=Suspendisse potenti...`
  - `Delivering plain text line to console | lineLength=819 preview=In accumsan elit...`
  - `Delivering plain text line to console | lineLength=934 preview=Donec sed mauris...`
  - `Delivering plain text line to console | lineLength=726 preview=Praesent imperdiet...`
- These lines are appended via `appendSessionChatLine`, so data is present in `consoleLines`.
- The missing paragraphs match earlier long‑message paragraphs sent moments before.

### Root Cause (UI Layer)
`ConsoleView` was grouping lines by `contentSignature` within a 30‑second window even when they were not marked as duplicates. This collapsed repeated paragraphs from subsequent tests into the earlier long‑message entries, making it look like only the first paragraph arrived.

### Actions Taken (Feb 6, 2026)
1. **Restrict duplicate grouping to explicit duplicates only**:
   - In `ConsoleView.groupedLines`, only collapse lines where `line.isDuplicate == true`.
   - Repeated messages (same content, same path) now render as distinct lines.

### Expected Outcome
- Repeated long‑message paragraphs should appear in full, even if the same content was sent moments earlier.
- Only true path‑based duplicates (same content received via different digipeater paths) are collapsed under a single entry.
