# Log Output Examples

This document shows what the diagnostic logs look like in practice, so you know what to expect in Console.app.

## Normal Operation (No Issues)

### Initial Connection
```
[General] [Config] Diagnostic logging configuration updated
[BLE] [BLE TNC4] Service discovered: 49535343-FE4D-4BD9-BA61-23C647249616 {known=no}
[BLE] [BLE TNC4] Service discovered: 00000001-BA2A-46C9-AE49-01B0961F68BB {known=yes}
[BLE] [BLE TNC4] Characteristic discovered: 49535343-1E4D-4BD9-BA61-23C647249616 {service=49535343-FE4D-4BD9-BA61-23C647249616, properties=write|writeNoResp}
[BLE] [BLE TNC4] Characteristic discovered: 49535343-8841-43F4-A8D4-ECBE34729BB3 {service=49535343-FE4D-4BD9-BA61-23C647249616, properties=notify}
[BLE] [BLE TNC4] Characteristic discovered: 00000002-BA2A-46C9-AE49-01B0961F68BB {service=00000001-BA2A-46C9-AE49-01B0961F68BB, properties=write|writeNoResp}
[BLE] [BLE TNC4] Characteristic discovered: 00000003-BA2A-46C9-AE49-01B0961F68BB {service=00000001-BA2A-46C9-AE49-01B0961F68BB, properties=notify}
[BLE] [BLE TNC4] TX characteristic selected: 00000002-BA2A-46C9-AE49-01B0961F68BB {priority=3, reason=Known service UUID match}
[BLE] [BLE TNC4] RX characteristic selected: 00000003-BA2A-46C9-AE49-01B0961F68BB {priority=3, reason=Known service UUID match}
[BLE] [BLE TNC4] Subscription change for 00000003-BA2A-46C9-AE49-01B0961F68BB {state=enabled, result=success}
```

### Normal Packet Reception
```
[KISS] [BLE TNC4] Frame complete: DATA {port=0, command=0, size=42}
Hex dump (42 bytes):
0000: C0 00 AE 92 88 8A 62 40 E0 AE 92 88 8A 64 61 03  ......b@.....da.
0010: F0 3E 41 50 52 53 20 54 65 73 74 20 4D 65 73 73  .>APRS Test Mess
0020: 61 67 65 20 23 31 32 33 C0                       age #123.

[AX.25] [BLE TNC4] Frame: KB1XYZ-7 → APRS-0 (UI) {src=KB1XYZ-7, dst=APRS-0, type=UI, control=0x03, info_size=30}
[Reception] [BLE TNC4] Packet #1 {timestamp=1.234, bytes=42, total_bytes=42}
[KISS] [BLE TNC4] Frame complete: DATA {port=0, command=0, size=45}
[AX.25] [BLE TNC4] Frame: N2ABC-9 → CQ-0 (UI) {src=N2ABC-9, dst=CQ-0, type=UI, control=0x03, info_size=28}
[Reception] [BLE TNC4] Packet #2 {timestamp=2.456, bytes=45, total_bytes=87}
[KISS] [BLE TNC4] Frame complete: DATA {port=0, command=0, size=38}
[AX.25] [BLE TNC4] Frame: W3DEF → KB1XYZ-7 (I(N(S)=0, N(R)=0)) {src=W3DEF, dst=KB1XYZ-7, type=I(N(S)=0, N(R)=0), control=0x00, info_size=20}
[Reception] [BLE TNC4] Packet #3 {timestamp=3.789, bytes=38, total_bytes=125}
```

## Bug: Characteristic Override

### What You'll See When Bug Occurs
```
[BLE] [BLE TNC4] Service discovered: 49535343-FE4D-4BD9-BA61-23C647249616 {known=no}
[BLE] [BLE TNC4] TX characteristic selected: 49535343-1E4D-4BD9-BA61-23C647249616 {priority=1, reason=Heuristic (writable)}
[BLE] [BLE TNC4] RX characteristic selected: 49535343-8841-43F4-A8D4-ECBE34729BB3 {priority=1, reason=Heuristic (notifiable)}
[BLE] [BLE TNC4] Subscription change for 49535343-8841-43F4-A8D4-ECBE34729BB3 {state=enabled, result=success}

... normal operation for a few minutes ...

[BLE] [BLE TNC4] Service discovered: 00000001-BA2A-46C9-AE49-01B0961F68BB {known=yes}
[BLE] [BLE TNC4] ⚠️ TX CHARACTERISTIC OVERRIDE (BUG RISK!) {old=49535343-1E4D-4BD9-BA61-23C647249616, new=00000002-BA2A-46C9-AE49-01B0961F68BB, reason=Second service discovery}
[BLE] [BLE TNC4] ⚠️ RX CHARACTERISTIC OVERRIDE (BUG RISK!) {old=49535343-8841-43F4-A8D4-ECBE34729BB3, new=00000003-BA2A-46C9-AE49-01B0961F68BB, reason=Second service discovery}
[BLE] [BLE TNC4] Subscription change for 00000003-BA2A-46C9-AE49-01B0961F68BB {state=enabled, result=success}

... continued operation ...

[Reception] [BLE TNC4] ⏱️ RECEPTION GAP DETECTED {gap_duration=5.23, threshold=5.00}
[BLE] [BLE TNC4] 🚫 DATA FILTERED - Wrong characteristic! {received_from=49535343-8841-43F4-A8D4-ECBE34729BB3, expected=00000003-BA2A-46C9-AE49-01B0961F68BB, bytes_discarded=42}
[BLE] [BLE TNC4] 🚫 DATA FILTERED - Wrong characteristic! {received_from=49535343-8841-43F4-A8D4-ECBE34729BB3, expected=00000003-BA2A-46C9-AE49-01B0961F68BB, bytes_discarded=45}
[BLE] [BLE TNC4] 🚫 DATA FILTERED - Wrong characteristic! {received_from=49535343-8841-43F4-A8D4-ECBE34729BB3, expected=00000003-BA2A-46C9-AE49-01B0961F68BB, bytes_discarded=38}
[Reception] [BLE TNC4] ⏱️ RECEPTION GAP DETECTED {gap_duration=10.45, threshold=5.00}
[Reception] [BLE TNC4] ⏱️ RECEPTION GAP DETECTED {gap_duration=15.67, threshold=5.00}
```

**Analysis:** The override happened, both characteristics are now notifying, but only the Microchip one is receiving data, which is then filtered out!

## KISS Frame Errors

### Truncated Frame
```
[KISS] [BLE TNC4] Frame start (FEND) {port=0, command=0}
[KISS] [BLE TNC4] Frame decode error: Truncated frame
Hex dump (12 bytes):
0000: C0 00 AE 92 88 8A 62 40 E0 AE 92 88              ......b@....
```

### Invalid Escape Sequence
```
[KISS] [BLE TNC4] Frame decode error: Invalid escape sequence
Hex dump (24 bytes):
0000: C0 00 AE 92 88 8A 62 40 E0 AE 92 88 8A 64 61 03  ......b@.....da.
0010: F0 DB FF 3E 41 50 52 53                          ...>APRS
```

### Framing with Escape Sequences (Verbose Mode)
```
[KISS] [BLE TNC4] Frame start (FEND) {port=0, command=0}
[KISS] [BLE TNC4] Escape sequence: 0xDB → 0xC0 (escaped FEND)
[KISS] [BLE TNC4] Escape sequence: 0xDD → 0xDB (escaped ESC)
[KISS] [BLE TNC4] Frame end (FEND) {frame_size=42}
[KISS] [BLE TNC4] Frame complete: DATA {port=0, command=0, size=42}
```

## AX.25 Protocol Issues

### Invalid Callsign Encoding
```
[AX.25] [BLE TNC4] Parse error: Invalid callsign encoding
Hex dump (15 bytes):
0000: AE 92 88 8A 62 40 E0 FF FF FF FF FF FF 03 F0     ....b@..........
```

### Malformed Header
```
[AX.25] [BLE TNC4] Parse error: Frame too short for AX.25 header
Hex dump (8 bytes):
0000: AE 92 88 8A 62 40 E0 03                          ....b@..
```

### Different Frame Types
```
[AX.25] [BLE TNC4] Frame: KB1XYZ-7 → CQ-0 (UI) {src=KB1XYZ-7, dst=CQ-0, type=UI, control=0x03, info_size=30}
[AX.25] [BLE TNC4] Frame: N2ABC → KB1XYZ-7 (SABM) {src=N2ABC, dst=KB1XYZ-7, type=SABM, control=0x2F}
[AX.25] [BLE TNC4] Frame: KB1XYZ-7 → N2ABC (UA) {src=KB1XYZ-7, dst=N2ABC, type=UA, control=0x63}
[AX.25] [BLE TNC4] Frame: N2ABC → KB1XYZ-7 (I(N(S)=0, N(R)=0)) {src=N2ABC, dst=KB1XYZ-7, type=I(N(S)=0, N(R)=0), control=0x00, info_size=128}
[AX.25] [BLE TNC4] Frame: KB1XYZ-7 → N2ABC (RR(N(R)=1)) {src=KB1XYZ-7, dst=N2ABC, type=RR(N(R)=1), control=0x21}
```

## Reception Gap Tracking

### Normal Operation
```
[Reception] [BLE TNC4] Packet #1 {timestamp=1.234, bytes=42, total_bytes=42}
[Reception] [BLE TNC4] Packet #2 {timestamp=2.456, bytes=45, total_bytes=87}
[Reception] [BLE TNC4] Packet #3 {timestamp=3.789, bytes=38, total_bytes=125}
[Reception] [BLE TNC4] Packet #4 {timestamp=4.123, bytes=52, total_bytes=177}
```

### Gap Detected
```
[Reception] [BLE TNC4] Packet #10 {timestamp=15.234, bytes=42, total_bytes=420}
[Reception] [BLE TNC4] ⏱️ RECEPTION GAP DETECTED {gap_duration=6.45, threshold=5.00}
[Reception] [BLE TNC4] Packet #11 {timestamp=21.684, bytes=45, total_bytes=465}
```

### Summary Report
```
[Reception] [BLE TNC4] Summary {packets=142, bytes=6234, uptime=120.5, rate=1.18 pkt/s}
```

## Performance Timing (Comprehensive Mode)

### Operation Timing
```
[Performance] [BLE TNC4] ⏱️ parse_kiss_frame {duration_ms=0.234}
[Performance] [BLE TNC4] ⏱️ decode_ax25_header {duration_ms=0.156}
[Performance] [BLE TNC4] ⏱️ process_info_field {duration_ms=1.234}
[Performance] [BLE TNC4] ⏱️ ble_write_operation {duration_ms=5.678}
```

## Complete Diagnostic Session Example

### From Connection to Bug Detection
```
2026-03-02 10:15:23.456 [Config] Diagnostic logging configuration updated
2026-03-02 10:15:24.123 [BLE] [BLE TNC4] Service discovered: 49535343-FE4D-4BD9-BA61-23C647249616 {known=no}
2026-03-02 10:15:24.145 [BLE] [BLE TNC4] Characteristic discovered: 49535343-1E4D-4BD9-BA61-23C647249616 {service=49535343-FE4D-4BD9-BA61-23C647249616, properties=write|writeNoResp}
2026-03-02 10:15:24.147 [BLE] [BLE TNC4] Characteristic discovered: 49535343-8841-43F4-A8D4-ECBE34729BB3 {service=49535343-FE4D-4BD9-BA61-23C647249616, properties=notify}
2026-03-02 10:15:24.149 [BLE] [BLE TNC4] TX characteristic selected: 49535343-1E4D-4BD9-BA61-23C647249616 {priority=1, reason=Heuristic (writable)}
2026-03-02 10:15:24.151 [BLE] [BLE TNC4] RX characteristic selected: 49535343-8841-43F4-A8D4-ECBE34729BB3 {priority=1, reason=Heuristic (notifiable)}
2026-03-02 10:15:24.234 [BLE] [BLE TNC4] Subscription change for 49535343-8841-43F4-A8D4-ECBE34729BB3 {state=enabled, result=success}
2026-03-02 10:15:25.123 [BLE] [BLE TNC4] Service discovered: 00000001-BA2A-46C9-AE49-01B0961F68BB {known=yes}
2026-03-02 10:15:25.145 [BLE] [BLE TNC4] Characteristic discovered: 00000002-BA2A-46C9-AE49-01B0961F68BB {service=00000001-BA2A-46C9-AE49-01B0961F68BB, properties=write|writeNoResp}
2026-03-02 10:15:25.147 [BLE] [BLE TNC4] Characteristic discovered: 00000003-BA2A-46C9-AE49-01B0961F68BB {service=00000001-BA2A-46C9-AE49-01B0961F68BB, properties=notify}
2026-03-02 10:15:25.149 [BLE] [BLE TNC4] ⚠️ TX CHARACTERISTIC OVERRIDE (BUG RISK!) {old=49535343-1E4D-4BD9-BA61-23C647249616, new=00000002-BA2A-46C9-AE49-01B0961F68BB, reason=Second service discovery}
2026-03-02 10:15:25.151 [BLE] [BLE TNC4] ⚠️ RX CHARACTERISTIC OVERRIDE (BUG RISK!) {old=49535343-8841-43F4-A8D4-ECBE34729BB3, new=00000003-BA2A-46C9-AE49-01B0961F68BB, reason=Second service discovery}
2026-03-02 10:15:25.234 [BLE] [BLE TNC4] Subscription change for 00000003-BA2A-46C9-AE49-01B0961F68BB {state=enabled, result=success}
2026-03-02 10:15:26.123 [KISS] [BLE TNC4] Frame complete: DATA {port=0, command=0, size=42}
2026-03-02 10:15:26.125 [AX.25] [BLE TNC4] Frame: KB1XYZ-7 → APRS-0 (UI) {src=KB1XYZ-7, dst=APRS-0, type=UI, control=0x03, info_size=30}
2026-03-02 10:15:26.126 [Reception] [BLE TNC4] Packet #1 {timestamp=1.670, bytes=42, total_bytes=42}

... normal operation for several minutes ...

2026-03-02 10:20:45.456 [Reception] [BLE TNC4] Packet #142 {timestamp=321.000, bytes=45, total_bytes=6234}
2026-03-02 10:20:50.789 [Reception] [BLE TNC4] ⏱️ RECEPTION GAP DETECTED {gap_duration=5.33, threshold=5.00}
2026-03-02 10:20:50.801 [BLE] [BLE TNC4] 🚫 DATA FILTERED - Wrong characteristic! {received_from=49535343-8841-43F4-A8D4-ECBE34729BB3, expected=00000003-BA2A-46C9-AE49-01B0961F68BB, bytes_discarded=42}
2026-03-02 10:20:51.234 [BLE] [BLE TNC4] 🚫 DATA FILTERED - Wrong characteristic! {received_from=49535343-8841-43F4-A8D4-ECBE34729BB3, expected=00000003-BA2A-46C9-AE49-01B0961F68BB, bytes_discarded=45}
2026-03-02 10:20:55.890 [Reception] [BLE TNC4] ⏱️ RECEPTION GAP DETECTED {gap_duration=10.44, threshold=5.00}
```

**Clear diagnosis:** The override at 10:15:25 led to data filtering at 10:20:50 when the wrong characteristic started receiving packets.

## How to Filter in Console.app

### Filter by Subsystem
```
subsystem:com.rosswardrup.AXTerm
```

### Filter by Category
```
category:AX25Diagnostics
```

### Filter by Endpoint
```
subsystem:com.rosswardrup.AXTerm AND "BLE TNC4"
```

### Filter for Errors Only
```
subsystem:com.rosswardrup.AXTerm AND (error OR warning OR "⚠️" OR "🚫")
```

### Filter for Specific Event Type
```
subsystem:com.rosswardrup.AXTerm AND "[BLE]"
subsystem:com.rosswardrup.AXTerm AND "[KISS]"
subsystem:com.rosswardrup.AXTerm AND "[AX.25]"
subsystem:com.rosswardrup.AXTerm AND "[Reception]"
```

### Filter for Bug Detection
```
subsystem:com.rosswardrup.AXTerm AND ("OVERRIDE" OR "FILTERED" OR "GAP DETECTED")
```

## What Good Logs Look Like

✅ Priority 3 characteristics selected  
✅ Single subscription (no override)  
✅ Regular packet reception  
✅ No filtering warnings  
✅ No gap warnings  
✅ Clean KISS frame decoding  
✅ Valid AX.25 frames  

## What Bad Logs Look Like

❌ Characteristic override warnings  
❌ Data filtered messages  
❌ Reception gap detected  
❌ KISS frame decode errors  
❌ AX.25 parse errors  
❌ Subscription failures  

## Using Logs for Bug Reports

When reporting an issue, export logs showing:

1. **Connection sequence** (first 30 seconds)
2. **Normal operation** (sample period)
3. **Problem occurrence** (when issue manifests)
4. **Error messages** (any warnings/errors)
5. **Timing information** (timestamps of key events)

This gives complete context for debugging.
