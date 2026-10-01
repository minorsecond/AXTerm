# Live RF test log: two AXTerm stations on 2 m, 2026-09-30

Two AXTerm test instances talked to each other over the air on 145.070 MHz FM
simplex, to prove packet file transfer, the BBS and Winlink peer-to-peer end
to end on real radios. This log records what was tested, what passed, every
problem found, and what is left. Testing paused for the night at 20:05 MDT.

## Setup

| | Station A | Station B |
|---|---|---|
| callsign | K0EPI-2 | K0EPI-3 |
| radio | IC-705, about 0.2 W | ID-50, low power (about 2% of 10 W) |
| modem | AXTerm's sound modem through Warbler (`localhost:50100`) | Mobilinkd TNC4, firmware 2.5.14, USB serial `/dev/cu.usbmodem204B316146521` |
| TX delay | default | 800 ms (raised during the test, see finding 3) |
| window | left half of display 1 | right half of display 1 |

Both instances ran in test mode (separate settings and packet databases under
`~/Library/Containers/com.rosswardrup.AXTerm/Data/tmp/AXTerm-Test/`). Test mode
wipes settings at launch, so each relaunch needs the radio set up again. Test
files and their SHA-256 sums are in the session scratchpad (`rf/sums.txt`):
`t256_allbytes.bin` (256 bytes, every byte value), `t1k_bin.bin` (1 KB random),
`t3k_text.txt` (3 KB text), `t20k_bin.bin` (20 KB random).

## Results so far

| # | test | result |
|---|---|---|
| 1 | connect A to B direct (XID, SABM, UA), 2.0 s round trip | pass |
| 2 | text chat both ways over the session | pass, with display bugs 2 and 3 below |
| 3 | AXDP capability handshake | pass once, but a lost PONG is never retried (bug 1) |
| 4 | AXDP A to B, 256 bytes | pass, byte-identical |
| 5 | AXDP A to B, 1 KB | pass, byte-identical (after the USB fix) |
| 6 | YAPP B to A, 3 KB text | pass, byte-identical, about a minute, about 400 bps |
| 7 | AXDP B to A, 20 KB, with pause and resume in the middle | pass, byte-identical, about 14 minutes |
| 8 | incoming offer prompt, accept | pass (A and B, AXDP and YAPP) |
| 9 | received file saved to `~/Downloads/AXTerm Transfers` with Quick Look, Show in Finder, Open | pass |

## Findings

### 1. TNC4 resets itself after a large USB write (fixed, 064c53a)

The TNC4 dropped off USB again and again, about 8 seconds after AXTerm sent it a
frame. Reproduced with a Python probe and no AXTerm involved:

- a single `write()` of more than 64 bytes (one USB CDC packet) leaves the frame
  untransmitted, and the TNC4 resets 8.2 s later
- back-to-back small writes that coalesce past 64 bytes do the same
- 8.19 s is the STM32 independent watchdog (prescaler 64, reload 4095), so the
  firmware hangs in the USB receive path and the watchdog restarts it

Fix: `KISSLinkSerial` paces USB serial writes in 32-byte pieces at least 10 ms
apart, across frame boundaries. Bluetooth is not paced. Zero resets in more than
an hour of transfers since. Tests: `KISSLinkSerialPacingTests`,
`KISSLinkSerialPacingWaitTests`.

Firmware: 2.5.14 (August 2024) is the latest and there is no public report of
this. The likely culprit is the CDC receive handling in `Core/TNC/UsbPort.cpp`.
Worth reporting to support@mobilinkd.com or groups.io/g/mobilinkd. An optional
A/B test is flashing 2.5.10 by DFU (STM32CubeProgrammer 2.17 or later, or
dfu-util).

### 2. Receive problems were the radio, not AXTerm

- Earlier in the day, poor decoding on the 705 was its notch filter left on.
  That led to the rig-prep feature (detect, offer to fix, restore on close).
- The ID-50's volume was high enough to clip the TNC4 input. With the volume
  turned down, A to B delivery went from 53% of frames to 81%, then to about
  100% once the 800 ms TX delay was also in place.

### 3. B answered while the 705 was still keyed

Through Warbler's network audio, the 705 stays keyed about 0.7 s after its frame
ends. B's TNC4 answered inside that window and A never heard the start of the
reply. Raising B's TX delay to 800 ms made the preamble outlast the hang time.
During the 20 KB transfer, A heard 59 of B's 61 I-frames and B heard all 33 of
A's acks, with no retransmissions.

### 4. Why transfers are slow (about 300 bps on a 1200 baud link)

One exchange during the 20 KB AXDP transfer, timed from both stations' databases
(same Mac, same clock):

| step | time |
|---|---|
| B writes two I-frames (128 + 46 bytes, one 174-byte AXDP chunk), the second with P=1 | 0 |
| A decodes the first frame (800 ms TX delay, about 1.05 s airtime, decode latency) | +2.33 s |
| A decodes the second frame | +2.77 s |
| A sends RR F=1 | +2.79 s (23 ms after decoding, so the poll works) |
| B hears the RR (A's key-up path through Warbler and the 705) | +4.38 s |
| B writes the next chunk | +4.43 s |

About 2.6 s of each 4.4 s exchange is dead air, and only 174 bytes move per
exchange because the window is K=2 with paclen 128. The adaptive controller
cannot raise either during the session: the spec (§7.8) fixes K and paclen at
connection time, and every session starts from the defaults (K=2, paclen 128).
A session that starts on a lossy link stays slow after the link recovers. See
improvement I-1.

The USB resets (finding 1) made things far worse earlier in the day: a reset
costs at least 8 s plus reconnection, and every frame in flight.

## Bugs found

Status is filled in as each is fixed.

| # | bug | where seen | status |
|---|---|---|---|
| 1 | AXDP capability PING/PONG is never retried. A lost PONG leaves the Send File sheet on "Checking…" until a 15-minute timeout, offering only YAPP. AXDP was confirmed later only because B's chat message implied it. | A, 17:36 | open |
| 2 | After a chat message is acked at the link layer (RR received, no retransmission), the message still shows "Queued" and the header still says "Sending…". Both stations. | A and B, 17:40 | open |
| 3 | The terminal's To field lost keystrokes to its suggestion popover: typing K0EPI-2 left just "K", and the field then locked to a session with "K" and could not be edited. | B, 17:40 | open |
| 4 | Send stays disabled on B until the session is picked in the sidebar, even though B is connected to K0EPI-2. Related to 3. | B, 17:41 | open |
| 5 | The connection note says "connected and polling, but nothing has passed … may not be answering" while both sides answer every 30 s keep-alive poll. | A, 17:37 | open |
| 6 | Changing the radio's transport (Serial to Bluetooth and back) clears the chosen serial device. | B, 17:54 | open |
| 7 | After Disconnect, or after a transport change, the old serial link keeps reconnecting and reopens the port, which also got in the way of probing the TNC4. | B, 18:11 | open |
| 8 | The receiver of a paused transfer keeps saying "Receiving" with a decaying rate and no sign that the sender paused. | A, 19:48 | open |
| 9 | The session log view would not scroll back reliably to earlier lines. | A, 17:38 | open |

Not bugs, recorded so nobody chases them again:

- The receiver's progress bar looked behind the sender's. Measured against each
  window's own bar, both were at 39%. An inactive window draws the fill gray.
- Auto routing refused to connect to a station never heard. That is intended;
  Direct works.
- The Bluetooth scan found nothing while the Mobilinkd configuration app held
  the TNC4's Bluetooth connection, and for a while after switching the TNC4 from
  USB. See improvement I-3.

## Improvements proposed

| # | improvement | status |
|---|---|---|
| I-1 | Let K and paclen grow during a session, within limits (details below). | approved 2026-09-30, planned for 2026-10-01 |
| I-2 | Fix the 705's transmit tail in Warbler; in AXTerm, add a diagnostic hint and leave TX delay manual (details below). | approved 2026-09-30, planned for 2026-10-01 |
| I-3 | When a Bluetooth scan finds no TNC, say that another app (such as the Mobilinkd configuration app) may be holding it. | open |

### I-1: K and paclen grow during a session

The session's AIMD window can shrink below its starting K on loss but never
grow above it, so the starting K (2 by default) is also the ceiling for the
whole session. Spec §7.8 freezes the rest. A session that starts on a bad link
stays slow after the link recovers, and that hurts reliability as much as speed.

Plan:

- The session ceiling becomes the most the link allows: the peer's
  XID-advertised window and N1, capped at K=4 and paclen 256 direct, with the
  existing one-rung-per-digipeater paclen ceiling.
- Each session starts at the last values confirmed for that peer, or K=2 and
  paclen 128 when there are none. It grows after a clean streak and halves on
  loss, using the probation logic in `TxAdaptiveSettings`.
- A new K takes effect only when nothing is outstanding. A new paclen applies
  only to frames built after the change, so nothing in flight is re-cut.
- Two sessions to the same peer still use the conservative merged values.
- No higher than K=4 at 1200 baud: four 256-byte frames already hold the channel
  about 7.5 s per burst.
- Amend spec §7.8 together with the code. Tests: growth on a clean streak,
  backoff on loss, the quiescent-point rule, the XID ceiling, the hop ceiling,
  and the multi-session merge.

Expected on the 2026-09-30 path (about 2.85 s of fixed overhead per exchange):
K2/128 about 315 bps, K4/128 about 590 bps, K4/256 about 800 bps. Measure it on
the air afterward.

### I-2: the 705's transmit tail

Through Warbler, the 705 keeps transmitting an unmodulated carrier about 0.7 s
after each frame. A TNC's carrier detect listens for tones, so the TNC4 treats
that as a clear channel and keys over it. This affects every station working a
705 through Warbler. Waiting it out in AXTerm would add dead air to every
exchange with every peer to make up for one transmitter.

Plan:

- Warbler: drop PTT as soon as the last audio has been played, with 100 to
  200 ms of margin. Look at it together with the stuck carrier from the end of
  this session, since both are PTT-release behavior. Filing these as Warbler
  issues needs a GitLab project token for `workshop/warbler`, which does not
  exist yet; until then they live here.
- AXTerm: leave TX delay manual. When the link layer sees first attempts at a
  reply fail repeatedly while the retries get through, suggest raising TX delay
  or checking the other station's transmitter tail. Unit-test the detection.
- After the Warbler fix, bring B's TX delay back down from 800 ms and confirm
  delivery holds.

## Plan for 2026-10-01

Before the radios come on:

- Implement I-1 test-first with the spec amendment.
- Implement the I-2 diagnostic hint test-first.
- Look at the Warbler PTT tail and the stuck carrier (I-2).

On the air, first confirm the fixes for bugs 1 to 9 and measure I-1's throughput
against the table above, then work through the list below.

## Left to test

1. YAPP A to B (choose YAPP in A's Protocol picker)
2. AXDP B to A with a small file (done with 20 KB; repeat small for timing)
3. Cancel a transfer partway, from the sender and from the receiver
4. An offer declined
5. Auto-accept from the allow list while the terminal is not on screen
6. BBS in both directions: list files, download text, download binary, upload
7. Winlink peer-to-peer message with a photo attachment
8. Link dropped mid-transfer (turn one radio off), both sides fail cleanly
9. The same matrix with AXDP turned off in Settings (forces YAPP everywhere)
10. Repeat after the fixes above, to confirm them on the air
11. Bluetooth TNC4 path (USB was used for everything today)

## Resuming

1. Warbler: re-enable transmit for the 705 (turned off for the night).
2. IC-705 to 145.070 FM, about 0.2 W; ID-50 to 145.070 FM, low power, no tone,
   volume at the level that stopped the clipping.
3. Quit the main AXTerm or disconnect the 705 in it, and close the Mobilinkd
   configuration app.
4. Launch the two test instances, set A on Warbler (`localhost:50100`, the
   password is typed by the operator) as K0EPI-2 and B on the TNC4 over USB
   with the Mobilinkd switch on, K0EPI-3, TX delay 800 ms.
5. Afterward, put the 705 back on 144.390 PKTFM at its usual power and the ID-50
   back on its usual channel.

## Incident at the end of the session

Around 20:00 the IC-705 hung transmitting an unmodulated carrier, stopped, then
started again on its own. Both AXTerm test stations were shut down at once and
nothing was connected to Warbler's KISS port afterward, so the later keying came
from Warbler itself. The operator turned the ID-50 off and disabled 705 transmit
in Warbler for the night. This belongs in Warbler's tracker, not AXTerm's.
