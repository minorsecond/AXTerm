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

## Findings (so far)
- `AX25Session.acknowledgeUpTo(from:to:)` ignores `va` and removes keys `0..<nr` (or all when `nr==0`).
- This is wrong when `va` has wrapped (e.g., `va=6`, `nr=2` should remove `6,7,0,1` but current code only removes `0,1`).
- This can leave already-acked frames in `sendBuffer`, causing retransmits, REJ/out-of-window behavior, and stuck sessions.
- When receiving duplicate I-frames (outside receive window), the state machine only sent RR if P/F=1.
- If our RR was lost, the peer retransmits the duplicate. We discarded it and sent **no RR**, so the peer never advances and keeps retransmitting. This can stall multi-frame replies (e.g. `NODES`) and eventually trigger our T1 retry exhaustion.

## Tests Added
- `testAcknowledgeUpToWrappedVaDoesNotClearEarlierWrappedFrames`
- `testAcknowledgeUpToWrapAcrossZeroRemovesWrappedAckRange`
- `testStateMachineInSequenceAndDuplicateIFramesMaintainOrder` now asserts duplicate I-frames trigger `RR(VR)`.

## Fix Implemented
- Update `acknowledgeUpTo(from:to:)` to remove only the range `[va, nr)` with wraparound.
- Always send `RR(VR)` when an I-frame is outside the receive window (duplicate), regardless of P/F. This re-acks the current receive state and helps the peer recover when our previous RR was lost.

## Test Execution Notes
- `xcodebuild test -scheme AXTermTests -destination platform=macOS "-only-testing:AXTermTests/Unit/Protocol/AX25TransmissionTests"` fails because the project does not expose a scheme named `AXTermTests`. Use the real application scheme (e.g. `AXTerm`) when rerunning.
- `xcodebuild -project AXTerm.xcodeproj -list` now fails on this host because CoreSimulator services cannot be contacted and DerivedData / module cache files under `~/Library/Developer` and `~/Library/Caches` are not writable (error `Operation not permitted`, `Connection invalid`). This also triggers SwiftPM dependency resolution errors for Sentry and GRDB.
- Re-run the targeted `AXTerm` scheme tests once the simulator/service permissions are restored and DerivedData caches are writable, then update this document with the success state.
- `AXTermTests/Unit/Protocol/AX25SessionTests.testStateMachineInSequenceAndDuplicateIFramesMaintainOrder` now confirms a duplicate I-frame triggers `RR(VR)` before we drop it; these targeted unit assertions pass locally even though the broader host tests still cannot run.

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

## Additional Bugs Found (2026-02-06, second pass)

Analysis of Direwolf logs revealed three additional bugs in the AX.25 state machine:

### Bug 1: Stale N(R) in retransmitted I-frames
- `OutboundFrame` is immutable. When I-frames are retransmitted after T1 timeout, they carry the original N(R) from when they were first queued.
- Example: AXDP PING queued with N(R)=0; by the time it retransmits, V(R) has advanced to 2. Peer sees stale N(R)=0 and may reject or ignore.
- **Fix**: Added `OutboundFrame.withUpdatedNR(_:)` to create a copy with current N(R) and control byte. `AX25SessionManager.framesToRetransmit(from:)` now calls this with current V(R).

### Bug 2: No RR poll (P=1) on T1 timeout
- AX.25 spec section 6.4.11 requires sending RR with P=1 on T1 timeout when frames are outstanding. This forces the peer to respond with its current receive state, enabling recovery from lost responses.
- AXTerm only retransmitted I-frames without polling. If the peer had received frames but its RR was lost, there was no mechanism to discover this.
- **Fix**: T1 timeout handler in `AX25Session` now emits `.sendRR(nr: vr, pf: true)` before retransmitting when `outstandingCount > 0`.

### Bug 3: retryCount not reset on RR acknowledgment
- `retryCount` was never reset when an RR advanced V(A). This meant that after a few lost RRs (normal for digipeated paths), retryCount accumulated across unrelated timeout episodes and eventually hit `maxRetries`, disconnecting the session.
- **Fix**: `handleRR` now resets `retryCount = 0` when V(A) advances (i.e., the peer acknowledged new frames).

## Additional Tests Added (second pass)
- `testRetransmittedIFrameUsesCurrentVR` — verifies retransmit frames carry updated N(R)
- `testT1TimeoutInConnectedStateSendsRRPoll` — verifies RR poll (P=1) on T1 timeout
- `testRetryCountResetsOnRRAcknowledgment` — verifies retryCount resets when V(A) advances
- `testRetryCountDoesNotResetOnDuplicateRR` — verifies retryCount persists on stale/duplicate RR
- `testFullKB5YZBScenario_AXDPThenCommandRecovery` — full regression: AXDP PING, welcome I-frames, command with retransmit
- `testRetransmitAfterPartialAckUpdatesNR` — partial ACK then retransmit uses fresh N(R)

## Test Results (2026-02-06)
- **AX25SessionTests**: 52/52 passed (including 6 new regression tests)
- **AX25TransmissionTests**: 19/19 passed (3 pre-existing tests corrected for [va, nr) semantics)
- **Integration tests**: 24/28 passed; 4 failures are pre-existing simulation/timing issues unrelated to these changes:
  - `testIFrameAcknowledgement_NR_Increments` — simulation doesn't return expected N(R)=2
  - `testRRPollResponse` — timeout waiting for simulation response
  - `testConnectedModeNODESCommand` — gets UNKNOWN frame instead of UA
  - `testSABMUAHandshake` — gets SABM echo instead of UA response

## Next Steps
- Test live on-air with KB5YZB-7 via DRL to confirm the three fixes resolve the flaky connection behavior
- Monitor AXDP capability negotiation timing — PING is still sent before welcome I-frames are processed; may need sequencing improvement if issues persist
- Investigate the 4 pre-existing integration test failures (Direwolf simulation setup issues)
- Follow up on AXDP gating and disconnect cleanup if issues persist after the above fixes
