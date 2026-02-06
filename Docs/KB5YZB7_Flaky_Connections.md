# KB5YZB-7 Flaky Connections / Missing Retries / N Command No Response

Date: 2026-02-06
Branch: bug/tx-flaky-kb5yzb (based on feature/tx)

## Summary
Observed flaky AX.25 session behavior when connecting to `KB5YZB-7` via digipeater `DRL`:

- First connection attempt: `?` sent but apparently never delivered; AXTerm did not retry and no response seen.
- After app restart and reconnection: `?` sent and two responses received from node.
- `N` command (nodes) sent multiple times; no response from KB5YZB-7 (BPQ) even though other terminal software receives a response.
- Disconnect button: AXTerm sends `DISC` repeatedly; node appears not to respond (eventually UA seen in logs for earlier session, but UI still reported disconnecting).

This doc will be updated as tests and fixes progress.

## Evidence
### Screenshots
- See user-provided screenshots: Image #1 and Image #2 in the thread context.

### AXTerm logs (excerpted)
- 06:18:39 — SABM sent to `KB5YZB-7` via `DRL`.
- 06:18:43 — UA received; session transitions to connected.
- 06:18:50 — `?` transmitted as I-frame payload (`0x3F 0x0D`).
- 06:19:04+ — T1 timeouts in connected state; retransmit logic runs.
- 06:20:24 — `DISC` sent, session enters disconnecting; repeated DISC as T1 timeout fires.
- 06:20:27 — UA received; session closes (normal disconnect).
- 06:21:18, 06:21:29, 06:21:52 — `N` transmitted as I-frame payload (`0x4E 0x0D`); no apparent response from KB5YZB-7.

### Direwolf logs (from ham-pi)
- 06:18:50 — `K0EPI-7>KB5YZB-7,DRL:(I ...)?<0x0d>` observed on air.
- 06:20:38, 06:20:40, 06:20:43, 06:21:18, 06:21:29, 06:21:52 — `N<0x0d>` observed on air.
- 06:20:24 — `DISC` observed on air; UA received at 06:20:27.

## Hypotheses
1. **AXDP capability negotiation interfering with plain-text command delivery**
   - AXDP discovery/handshake occurs immediately after connect (PING sent). If `capabilityStatus` stays pending, messages may queue or be gated.
2. **Window / sequence handling edge cases when non-AXDP traffic interleaves with AXDP handshake**
   - Logs show REJ and out-of-window I-frame handling (e.g., received `N(S)=3` while expecting `2`). Potentially causing peer to ignore application payloads.
3. **Retry logic for I-frames is not re-sending payloads consistently**
   - T1 retransmit shows `retransmitNS=[]` in places; payload may not get retransmitted after initial timeout.
4. **Disconnect path does not fully clear pending data / timers**
   - Continuous DISC until UA; if state machine gets stuck, may block subsequent request handling.

## Repro Steps
1. Connect to `KB5YZB-7` via `DRL`.
2. Send `?` (with CR).
3. Observe whether response arrives; note if retry occurs.
4. Send `N` (with CR) multiple times.
5. Use Disconnect button.
6. Reconnect and repeat.

## Expected
- If `?` or `N` is transmitted and no response received, AXTerm should retry per T1/T2 and application-level policies.
- `N` should elicit a nodes list from BPQ node (as seen with other clients).
- Disconnect should transition cleanly and stop sending DISC once UA is received.

## Actual
- `?` appears to transmit but does not elicit response; retry not observed for the first attempt.
- `N` repeatedly transmitted with no response.
- Disconnect enters disconnecting and keeps sending DISC for extended periods.

## Next Steps
- Locate session/AX25 retry logic around `sendBuffer` / `retransmitNS` selection.
- Inspect AXDP negotiation gating of outgoing payloads.
- Add tests to reproduce:
  - I-frame retransmission includes payloads for unacked frames.
  - Pending AXDP discovery does not block plain-text commands.
  - Disconnect sequence clears timers and pending queues.
- Fix behavior; update this doc with findings and test coverage.
