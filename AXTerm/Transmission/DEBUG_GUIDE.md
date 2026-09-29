# BLE Reception Issue - Quick Debug Guide

## Expected Behavior (✅ Fix Working)

### Connection Sequence Logs:
```
BLE connected: MTU(withResp)=512 MTU(noResp)=185
BLE discovered 2 services: 49535343-FE4D-4BD9-BA61-23C647249616, 00000001-BA2A-46C9-AE49-01B0961F68BB
====== CHAR DUMP ======
Svc 49535343-FE4D-4BD9-BA61-23C647249616: [49535343-1E4D-4BD9-BA61-23C647249616 16] [49535343-8841-43F4-A8D4-ECBE34729BB3 12]
=======================
Waiting for more service discoveries (pending: 1)
====== CHAR DUMP ======
Svc 00000001-BA2A-46C9-AE49-01B0961F68BB: [00000002-BA2A-46C9-AE49-01B0961F68BB 12] [00000003-BA2A-46C9-AE49-01B0961F68BB 16]
=======================
All services discovered, selecting best characteristics
Selected TX (priority 3): 00000002-BA2A-46C9-AE49-01B0961F68BB from service 00000001-BA2A-46C9-AE49-01B0961F68BB
Selected RX (priority 3): 00000003-BA2A-46C9-AE49-01B0961F68BB from service 00000001-BA2A-46C9-AE49-01B0961F68BB
Final characteristic selection: TX=00000002-BA2A-46C9-AE49-01B0961F68BB, RX=00000003-BA2A-46C9-AE49-01B0961F68BB
BLE RX notifications enabled for 00000003-BA2A-46C9-AE49-01B0961F68BB
Sending KISS transmit timing parameters
KISS init complete — BLE link ready
```

### During Operation:
- Steady packet reception (check terminal UI for new packets)
- No errors about "IGNORING bytes"
- No "subscription failed" errors
- BytesIn counter increasing regularly

---

## Problem Indicators (❌ Issue Present)

### Red Flag #1: Filtered RX Data
```
BLE RX: IGNORING 127 bytes from unexpected characteristic 49535343-1E4D-4BD9-BA61-23C647249616 (expected: 00000003-BA2A-46C9-AE49-01B0961F68BB)
```
**Meaning**: Packets arriving on Microchip RX but being filtered out because we selected Mobilinkd RX. This indicates:
- Mobilinkd RX stopped notifying, OR
- We incorrectly selected Microchip RX initially

### Red Flag #2: Unsubscribe Error (OLD CODE ONLY)
```
BLE RX subscription failed for 49535343-1E4D-4BD9-BA61-23C647249616: Error Domain=CBATTErrorDomain Code=913
```
**Meaning**: Attempted to unsubscribe from Microchip RX but failed. This should NOT appear with the new fix since we never unsubscribe.

### Red Flag #3: Early Init
```
Sending KISS transmit timing parameters
====== CHAR DUMP ======  <-- Mobilinkd service discovered AFTER init!
```
**Meaning**: KISS init fired before all services were discovered. This should NOT happen with the fix.

### Red Flag #4: Wrong Characteristic Selected
```
Final characteristic selection: TX=49535343-8841-43F4-A8D4-ECBE34729BB3, RX=49535343-1E4D-4BD9-BA61-23C647249616
```
**Meaning**: Microchip characteristics selected instead of Mobilinkd. Priority algorithm may not be working.

---

## Quick Diagnostic Commands

### Check Service Discovery:
```bash
grep "BLE discovered.*services" log.txt
```
Should show: `BLE discovered 2 services: ...`

### Check Characteristic Selection:
```bash
grep "Selected.*priority" log.txt
```
Should show:
- `Selected TX (priority 3): 00000002-...`
- `Selected RX (priority 3): 00000003-...`

### Check for Filtered Packets:
```bash
grep "IGNORING.*bytes" log.txt
```
Should be **EMPTY** if fix is working.

### Check Subscription Status:
```bash
grep "notifications.*for" log.txt
```
Should show: `BLE RX notifications enabled for 00000003-BA2A-46C9-AE49-01B0961F68BB`

### Check Init Timing:
```bash
grep -A5 "Final characteristic selection" log.txt
```
Should show KISS init AFTER characteristic selection.

---

## Characteristic UUIDs Reference

### Mobilinkd Service (GOOD - Priority 3)
- Service: `00000001-BA2A-46C9-AE49-01B0961F68BB`
- TX (write): `00000002-BA2A-46C9-AE49-01B0961F68BB`
- RX (notify): `00000003-BA2A-46C9-AE49-01B0961F68BB`

### Microchip Service (Fallback - Priority 1)
- Service: `49535343-FE4D-4BD9-BA61-23C647249616`
- TX (write): `49535343-8841-43F4-A8D4-ECBE34729BB3`
- RX (notify): `49535343-1E4D-4BD9-BA61-23C647249616`

**Fix ensures Mobilinkd characteristics are ALWAYS selected.**

---

## Common Questions

**Q: Why does TNC4 advertise two services?**  
A: Microchip service is the default/legacy firmware. Mobilinkd service is custom and contains actual KISS data.

**Q: Can both services deliver data?**  
A: In theory yes, but only Mobilinkd service delivers KISS frames. Microchip service may echo or deliver garbage.

**Q: What if I see "subscription failed for 49535343..."?**  
A: This is old code behavior (attempting to unsubscribe). New code never unsubscribes, so this error should not appear.

**Q: What if packets stop arriving?**  
A: Check for "IGNORING X bytes" errors. If present, Microchip RX is still notifying but data is filtered. File bug report with full logs.

**Q: How long should I test?**  
A: At least 10 minutes of active packet reception. Original issue occurred after several minutes of operation.

---

## Success Criteria

✅ **Connection establishes without errors**  
✅ **Mobilinkd characteristics selected (00000002/00000003)**  
✅ **No "IGNORING bytes" errors during operation**  
✅ **Packets received steadily for extended period**  
✅ **BytesIn counter increases regularly**  
✅ **Terminal shows packets from nearby stations**

---

## Failure Recovery

If fix doesn't work:
1. Save full debug log
2. Note timestamp when packets stopped
3. Search log for "IGNORING" errors around that time
4. Check which characteristic was delivering data
5. Report findings with log excerpt

---

## Contact

If issues persist:
- Attach full debug log
- Include screenshot showing packet stoppage
- Note how long connection worked before failing
- Specify macOS version and Bluetooth hardware
