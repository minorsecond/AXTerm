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
