# Constitution retest, 2026-10-11

A (705) and the iPad on `c59778b8`, 145.650. A called the iPad (K0EPI-2 to
K0EPI-3, XID and SABM at 10:30:20Z) and sent the 26.8 KB constitution as one
block from the terminal.

## Results

| Step | Result | Notes |
|---|---|---|
| Long message A to the iPad | Plain text, finding 1 | No AXDP: no probe went out, so A did not count the iPad as AXTerm. 128-byte frames, K 2 |
| The iPad receiving it | Jumps, finding 2 | The history bounced as each line arrived |
| Photo by AXDP, K0EPI-3 to K0EPI-2, Medium | Confusing, finding 4 | "HEIC, smaller" came out 22 KB against JPEG's 20 KB |
| Mid-send stall | 31 s, finding 3 | Five bursts from A never reached the iPad; the operator heard the 705 send an unmodulated carrier once |

## Findings

1. **Two AXTerm terminals no longer find each other.** Since the probe
   rules of 2026-10-10 (retest finding 6) the probe goes after the other
   station's first data only if it says AXTerm, and the fallback for a
   silent station only to one remembered as AXTerm; the memory started
   empty, and a terminal sends no greeting. Operator: check every station
   once when connecting, either side, and cache the answer. Agreed design:
   one probe after the first data or after 15 s; the answer kept 30 days
   either way, AXTerm with its capabilities so a known station starts
   confirmed with no probe; passive signs fill the cache at no airtime cost
   (an APRS beacon to `APZAXT`, AXDP heard on the channel, a greeting that
   says AXTerm, the operator's own callsign at any SSID); and a Check for
   AXDP action on the session badge.
2. **The iPad's history jumps while plain-text lines arrive.** Each new line
   scrolls to the marker below the padding, which overshoots, and the repin
   then moves back to the last line. Finding 10 of the previous run fixed the
   status row's path, not this one. Fix: new lines scroll to the same target
   the repin uses.
3. **Five bursts from A never reached the iPad (Warbler suspected, not
   AXTerm).** A sent I(1) and I(2) at 10:37:51Z, after the iPad's RR 1, and
   resent them on T1 at 10:37:59, 10:38:06 and 10:38:14; the iPad's log
   shows nothing received between 10:37:51 and 10:38:22 (its clock about
   1.4 s behind A's), then decoded the fifth copy at once and answered RR 3.
   No partial or garbled frames in between, and the operator heard the IC-705
   key up with an unmodulated carrier during the stall. AXTerm handed every
   burst to Warbler and retried on schedule. Next: Warbler's log on the hub
   for 10:37:51 to 10:38:22Z (audio underrun, output device, PTT without
   audio).
4. **"HEIC, smaller" can come out bigger than JPEG.** Each photo size is a
   byte budget (Medium 25 KB): the shrinker takes the largest picture and
   highest quality that fit. HEIC packs more picture per byte, so it fitted a
   larger or higher-quality picture and landed at 22 KB where JPEG had to
   drop to a smaller picture at 20 KB. The label and its hint promise less
   airtime. Approved fix: the size sets the resolution, and each format is
   encoded at the lowest quality setting that still looks right (structural
   similarity of at least 0.95 against the scaled original, found by binary
   search). The byte budget becomes a cap: when the look does not fit it, the
   resolution steps down, and the step chosen is the one that looks best
   when viewed at the size's resolution. The summary gives both sizes, for
   example "11 KB as HEIC (JPEG would be 21 KB)".
5. **The iPad never learns that K0EPI-4 is AXTerm, so Send File shows no
   area picker.** The badge reads "No answer". Both logs agree on what
   happened, twice (10:53 and 10:54Z): the iPad got the mailbox greeting
   (which says AXTerm), sent the `AXDP?` probe at once, and A answered with
   its PING within 0.1 s. About 2.2 s after the greeting the iPad sent the
   RR for it, on its normal delayed-ack timer, and that RR went out on top of
   A's PING: A never logged the RR (it resent the greeting with a poll
   9 s later) and the iPad never logged the PING. The TNC4 tells the iPad
   nothing about carrier, so the iPad's ack hold cannot see A's reply
   coming. The single probe then timed out, and the iPad now remembers
   K0EPI-4 as "not AXDP" for a day (`axdpPeerMemory`, 04:54:43 local), so it
   will not ask again even after reconnecting. The probe and its reply are
   UI frames, which AX.25 never resends, and finding 6 of the last run cut
   AXTerm's own retries to none. Approved fix (AX.25 behavior, operator,
   2026-10-11), which also replaces the probe step of finding 1's design:
   - A station with an AXTerm sign (its greeting says AXTerm, we remember
     it as AXTerm, its APRS beacon goes to `APZAXT`, or we heard it send
     AXDP) is asked inside the connection: an AXDP PING as an I-frame, with
     the reply the same way. AX.25 resends either if it is lost, and each
     carries the acknowledgment in its header, so no separate RR is left to
     collide. The cost is the capability data, about 50 bytes each way.
   - A station with no sign gets one UI probe, sent in the same
     transmission as the pending RR, and the answer is cached as finding 1
     describes.
   - A sign outranks a cached "not AXDP": that station is asked again.
   - A station remembered as AXTerm starts confirmed and is not asked.
   Next, approved (operator, 2026-10-11): an AXTerm marker in the XID both
   sides already exchange, a few bytes and no extra frames. The source
   reading is in `Docs/XIDCapabilityMarkerResearch.md`: an unassigned PI,
   last in group 0x80, PL exactly 4, GL counted exactly, not PI 16 or 17
   (BPQ's compression), and an answer that differs from the question,
   since BPQ builds its XID response by editing the frame it received and
   so echoes unknown parameters. A reply without the answer means not
   AXTerm, with nothing more sent. Unit tests first, then loopback tests
   against Dire Wolf, LinBPQ and a kernel stack, without transmitting. Once
   it is in, the UI probe goes only when no memory, sign or XID could
   answer, and for Check Again. Two side findings from the same reading,
   each AX.25 behavior to look at on loopback first: Dire Wolf ignores an
   XID that arrives before the SABM, so AXTerm's first call to a Dire Wolf
   station waits one RTO; and BPQ probably reads PI 2 and 3 with bytes 1
   and 3 swapped against AXTerm, so it may never answer AXTerm's XID with
   an XID (inferred from its constants, not observed).

## Fixes

Each fixed test first: the new tests were built against the old code and
failed to compile on the missing pieces, then passed with the fix. The full
macOS suite (9,634 tests) and the iOS build passed before the commits. Not
yet installed on A (705) or the iPad.

| Finding | Commit | What changed |
|---|---|---|
| 1, 5 | `bb06b170` | Either side checks once per connection; a station with an AXTerm sign is asked inside the session, any other gets one UI probe right after the held RR; answers and capabilities kept 30 days; APZAXT beacons and heard AXDP count as signs; Check Again on the "No answer" badge |
| 2 | `eb0a03ca` | New lines scroll to the last line, as the repin does |
| 3 | none | Warbler, not AXTerm; its log on the hub is still to be read |
| 4 | `8885f749` | Each size sets the resolution; each format gets the lowest quality that keeps SSIM 0.95, with the budget as a cap; the preview gives both sizes |

The first full run after these changes failed 14 tests in two groups, both
from the check now being scheduled on both sides: opening Send File or
starting a transfer skipped a check that was scheduled but had not run.
An explicit request now runs it at once. The tests that assumed the UI
probe for a station whose greeting says AXTerm now wait out the longer
in-session check.
