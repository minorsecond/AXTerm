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

## Results on 2026-10-01

| # | test | result |
|---|---|---|
| 10 | To field: typing k0epi-3 key by key (bug 3) | pass, uppercased, nothing lost, field stays editable |
| 11 | chat both ways, send state clears on the ack (bug 2), Send enabled on B without the sidebar (bug 4) | pass; B's reply needed 2 retries (bug 11) |
| 12 | Send File sheet shows AXDP confirmed, no "Checking…" (bug 1) | pass |
| 13 | YAPP A to B, 3 KB text | pass, byte-identical (saved as "t3k_text 2.txt" beside last night's copy) |
| 14 | offer declined | pass, labels inconsistent (bug 13) |
| 15 | pause on the sender: receiver shows "Waiting for K0EPI-2" with no rate (bug 8); resume | pass |
| 16 | cancel from the receiver mid-transfer | pass |
| 17 | AXDP B to A, 1 KB, "Always Accept" from the prompt | pass, byte-identical, 47 s from Send to saved file |
| 18 | auto-accept from the allow list with the terminal off screen | pass, no prompt (bug 16: no visible sign either) |
| 19 | cancel from the sender mid-transfer | pass, receiver logs "K0EPI-3 canceled the transfer" |
| 20 | BBS: B shares a folder (bug 17 fix), A calls K0EPI-8, new-caller questions | pass after bugs 18 to 20 below; Return in an empty field sent nothing (bug 21) |
| 21 | BBS: `W TEST` lists the area | pass |
| 22 | BBS: `D t3k_text.txt` (text, typed out) | received, but only as transcript lines (improvement I-4) |
| 23 | BBS: `D t1k_bin.bin` (binary by YAPP) | pass, byte-identical, about 25 s |
| 24 | BBS: `U` then a YAPP upload of t256_allbytes.bin | arrived byte-identical in the inbox, but A marked it failed (bug 22) |
| 25 | AXDP A to B, 20 KB, with in-session growth (I-1) | pass, byte-identical, about 10 min (about 270 bps); grew to K3 with whole 174-byte frames after 10 clean frames, then collapsed to K1, paclen 64 (bug 25) |
| 26 | AXDP A to B, 20 KB, growth off, standard T1 (rerun of 25) | pass, byte-identical (SHA-256 35e97e…), accepted 16:45:40 UTC, saved 16:56:42 (about 11 min, about 250 bps). A sent 332 I-frames for 321 distinct, so 11 resends (3%); one SREJ; B acked with 241 RRs and A heard 240. The hub played all 166 transmissions with nothing lost. A lost the radio for 15 s at 16:51:16 (bug 28) and the session rode through it |

Setup notes: Station B ran from a copy of the app with its own bundle ID
(`com.rosswardrup.AXTerm.stationb`, ad hoc signed without the iCloud
entitlements) so background UI control can address each station's windows.
Station A first failed with "This radio's link could not be created": the link
trusted the profile's saved-password flag, which test mode had reset, instead
of the Keychain (fixed, fc70878).

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
| 1 | AXDP capability PING/PONG is never retried. A lost PONG leaves the Send File sheet on "Checking…" until a 15-minute timeout, offering only YAPP. AXDP was confirmed later only because B's chat message implied it. | A, 17:36 | fixed, 78bbf32: the probe and PONG are UI frames, so nothing retransmitted them; the check now asks 3 times about one RTO apart (10 to 30 s), then shows "No answer" and offers YAPP |
| 2 | After a chat message is acked at the link layer (RR received, no retransmission), the message still shows "Queued" and the header still says "Sending…". Both stations. | A and B, 17:40 | fixed, 5f5ddf9: setting the callsign with the terminal open built a new terminal model that was never wired to the session callbacks, so sends and acks never reached it; it is rewired whenever the model changes |
| 3 | The terminal's To field lost keystrokes to its suggestion popover: typing K0EPI-2 left just "K", and the field then locked to a session with "K" and could not be edited. | B, 17:40 | fixed, 2915376: every keystroke committed the destination, and "K" fell back to the connected session and locked the field; the field now commits on a picked suggestion, Return or Connect, and binds only its own station |
| 4 | Send stays disabled on B until the session is picked in the sidebar, even though B is connected to K0EPI-2. Related to 3. | B, 17:41 | fixed, 0f5da3a (with 5f5ddf9): taking up a session left "K" in the To field, which is not a callsign; the field now names the session's station |
| 5 | The connection note says "connected and polling, but nothing has passed … may not be answering" while both sides answer every 30 s keep-alive poll. | A, 17:37 | fixed, 75af580: the note counted the peer's polls we answered; it now looks at whether our own polls were answered and says so |
| 6 | Changing the radio's transport (Serial to Bluetooth and back) clears the chosen serial device. | B, 17:54 | fixed, 683c957: the form cleared a device missing from /dev for 10 s and saved the empty path; it now stays chosen, marked unavailable |
| 7 | After Disconnect, or after a transport change, the old serial link keeps reconnecting and reopens the port, which also got in the way of probing the TNC4. | B, 18:11 | fixed, 0cc4b00: any settings write after Disconnect reopened every link, a transport change on the open page kept the old link, and a released serial link never closed its descriptor |
| 8 | The receiver of a paused transfer keeps saying "Receiving" with a decaying rate and no sign that the sender paused. | A, 19:48 | fixed, 91e9324: AXDP and YAPP have no pause message, so after a silence longer than max(15 s, 4 times the usual chunk gap) the receiver shows "Waiting for" the sender and hides the rate |
| 9 | The session log view would not scroll back reliably to earlier lines. | A, 17:38 | fixed, 8fa62c1: the console and raw log scrolled to the bottom on every new line; they now follow only while the reader is at the bottom |
| 10 | Found while fixing 3 and 4: data arriving from a second connected station switched the terminal to that session but left the To field on the first, so the next message went down the wrong link. | code review | fixed, 0b1bb83: the terminal takes up the sending session only when it has no live session, and the To field follows |
| 11 | Found on the air 2026-10-01: a single unpolled I-frame was resent before the peer's delayed ack could arrive. B's T1 fired after 4.3 s, while B's airtime plus A's 2 s T2 plus the 705's key-up path needs about 5.5 s, so the resend keyed over A's RR. The RTO is learned from polled exchanges, which are answered at once, so it does not cover the peer's T2 (spec: "T2 must sit inside every plausible peer T1"). | B, 10:44:53 UTC 2026-10-01 | fixed, bafeeee: a first send of unpolled frames waits for SRTT, our airtime and 3 s of peer ack delay; a poll and every retry keep the plain RTO |
| 12 | Pressing Return in the To field commits and connects, but the suggestion popover stays open over the transcript until Escape. | A, 10:42 UTC 2026-10-01 | open |
| 13 | Transfer end states disagree: a declined offer is a red "Failed: Transfer declined by remote station" on the sender and "Canceled" on the receiver, and a cancel by the other station does not say who canceled. | A and B, 10:51 UTC 2026-10-01 | open |
| 14 | After the receiver accepts, its own row reads "Pending permission" (the sender's wording) for a few seconds until data flows. | A, 10:53 UTC 2026-10-01 | open |
| 15 | Narrow-window layout: at half-screen width with the sidebar open, the locked To field in the compose bar and the Map's station-list title both wrap one or two characters per line. | A, 10:55 UTC 2026-10-01 | open |
| 16 | An auto-accepted transfer arriving while another view is on screen gives no visible sign that a file is coming in. | A, 10:55 UTC 2026-10-01 | open |
| 17 | Every BBS file pick did nothing: SwiftUI clears the importer's isPresented binding before calling the completion handler, and the Files screens kept the pick's purpose in that state. "Share a Folder" closed the panel and shared nothing, with no message. | B, 10:58 UTC 2026-10-01 | fixed, 738f67b |
| 18 | An XID addressed to the mailbox (K0EPI-8) was answered from the station callsign (K0EPI-3). | B, 11:42 UTC 2026-10-01 | fixed, 383c380 |
| 19 | When the radio came up but the sound modem would not start (Warbler restarting its virtual IC-705 at that moment), the link never retried, while its own status line said "still trying". | A, 11:42 UTC 2026-10-01 | fixed, 8837f31 |
| 20 | Possibly flaky under full-suite load: ModemRadioLinkTests.testATransmissionKeysAndUnkeysOverCIV failed once and passed 10 of 10 alone. | test suite | watch |
| 21 | Return in an empty compose field sent nothing, so a mailbox's "Press Return to skip" and node prompts could not be answered with a blank line. | A, 11:54 UTC 2026-10-01 | fixed, 1367c56 |
| 22 | The mailbox wrote "Received <file>" as soon as it acknowledged end of file, while the caller waited for the end-of-transmission ack; AXTerm's YAPP sender read the line as a protocol error and marked an intact upload failed. | A and B, 12:07 UTC 2026-10-01 | fixed, e31615c |
| 23 | A's AXDP check now retries three times, so every connect to a station without AXDP (most BBSes and nodes) sends three `AXDP?` UI frames instead of one. | A, 11:53 UTC 2026-10-01 | open, consider stopping after one try on a station already known not to answer |
| 24 | Warbler's IC-705 radio loop stalled at 11:42:26 UTC; its watchdog exited (code 70) and launchd restarted it 30 s later. B heard none of the three SABMs Warbler logged as keyed. | Warbler, 11:42 UTC 2026-10-01 | the hub journal shows it keyed all four transmissions and played their audio with nothing lost or late, then logged the Mac's warblerd going quiet at 11:42:41; the stall was in the Mac warblerd. Why B missed the SABMs is still open; B's serial logs for that minute had aged out |
| 25 | With the window grown to K3, the peer's T2 ack arrived mid-burst as RR F=0; the sender filled the freed slot at once and keyed over the peer's F=1 answer, and the losses dropped the session to K1, paclen 64. | A, 12:16 to 12:26 UTC 2026-10-01 | not fixed in the AX.25 layer: a poll hold (fde9358) was tried and reverted (14643a3) on the owner's call; growth switched off instead (e2c6e35), pending a receiver-side design |
| 26 | A heard six of its own frames back through the IC-705 between 16:32:54 and 16:34:29 UTC, each decoded within 6 ms of the moment B's TNC4 decoded the same frame. The echo of the AXDP text probe raised "Another station is transmitting as K0EPI-2": the probe is built without a control byte, the encoder sends 0x03 for that, and the echo memory recorded 0, so the copy matched nothing sent. | A, 16:33:12 UTC 2026-10-01 | false alarm fixed, 6436adf. Why the 705's receive stream carried our own transmissions for those 95 s is open. The 705 cannot receive while keyed, so its transmit monitor audio over LAN is the likeliest source |
| 27 | After 23 quiet minutes, B missed A's first five SABMs (16:31:21 to 16:32:22 UTC), decoded the sixth, and heard every frame after that. The hub logged all six keyed and played with nothing lost or late. Same pattern as bug 24. A receive level check on B at 16:21:41 found the TNC4 input fully clipped (clipped share 1.00 at gain 4, ID-50 volume 5) and no packets. | B, 16:31 UTC 2026-10-01 | open. Nobody touched either radio (the operator was out). Candidates: the ID-50's power save sleeping through short packets after a quiet spell, and input clipping (finding 2). A sent nothing between 16:08 and 16:31, so there was no longer outage to explain |
| 28 | At 16:51:16 UTC, mid-transfer, the hub took a new login for the virtual IC-705 from this Mac's Tailscale address (100.80.112.57) while the Mac's LAN session (192.168.3.14) still held the 705 keyed. The hub refused the new session's unkeys, then unkeyed the LAN session after it sent nothing for 3 s. AXTerm on A heard nothing for 10 s, dropped the radio link, and reconnected at 16:51:31; the AX.25 session survived and the transfer finished. Warbler's Mac log records no reconnect at that time. | Warbler, 16:51 UTC 2026-10-01 | open, Warbler: why warblerd moved from the LAN to Tailscale. Also seen: two `warblerd --radio ft710` processes running, and Warbler.log stamps local time with a `Z` suffix |

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
| I-1 | Let K and paclen grow during a session, within limits (details below). | built (b5de7e1), measured on the air, switched off by default (e2c6e35) because bursts outran the receiver's 2 s T2; needs a receiver-side design before it is switched on |
| I-2 | Fix the 705's transmit tail in Warbler; in AXTerm, add a diagnostic hint and leave TX delay manual (details below). | AXTerm hint done (962e1c5); AXTerm sends no trailing silence to Warbler (cba92c1); Warbler fixes on branch fix/ptt-safety, in progress |
| I-3 | When a Bluetooth scan finds no TNC, say that another app (such as the Mobilinkd configuration app) may be holding it. | done, b8c4ded |
| I-4 | Text downloads from a BBS become files: the mailbox marks a typed-out file with name and byte count, an AXTerm caller saves it to AXTerm Transfers with a Transfers row, and a Capture to file toggle covers any other BBS or node. | done, 07bf240 and e60b600; mailbox replies were already one send per command, so packing needed no change |

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

On the air, first confirm the fixes for bugs 1 to 10 and measure I-1's
throughput against the table above, then work through the list below.

Things the fixes changed that are worth checking by hand, since unit tests
cannot see them:

- Scroll the terminal log up during a session with keep-alives running; it
  should stay put, and pick up following again at the bottom (bug 9).
- After Disconnect, editing a radio's settings or leaving its page no longer
  reconnects it. Press Connect to bring it back (bug 7).
- Clearing the To field, or choosing a station with no session, leaves the
  terminal unbound even while another session is up; that session carries on
  in the sidebar (bug 3).
- Opening Send File for a station whose AXDP support is unknown now sends one
  `AXDP?` probe, also from the station that answered the call (bug 1).
- A receiver shows "Waiting for" the sender after max(15 s, 4 times the usual
  chunk gap) of silence. On a very lossy link a long retry gap can show it
  briefly (bug 8).

Left alone: the radio page still has no Disconnect while a link is retrying,
and a capability check that gave up is not retried until the session ends (a
"Check again" button would cover a link that improves mid-session).

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
started again. The operator turned the ID-50 off and disabled 705 transmit in
Warbler for the night.

What the logs show (read-only review of Warbler's code and logs on 2026-10-01;
the hub's own journal was not read):

- Port 50100 is Warbler's virtual IC-705, which speaks Icom's LAN protocol over
  UDP. The `lsof` check that night looked at TCP and proved nothing. The chain
  is AXTerm, then the Mac's warblerd, then the hub on ham-pi, then the 705 over
  its Wi-Fi.
- At 19:58:21 Station A keyed an over that ran 5.8 s with 1.6 s of audio. The
  705 stopped answering CI-V; Station A logged "Lost the radio: the radio has
  not answered 8 CI-V commands in a row" at 19:58:51 and reconnected at
  19:58:54. Warbler logged "the IC-705 stopped answering CI-V for 15 s" at
  19:59:25 and 20:00:43, while the FT-710 on the same hub stayed healthy. A
  radio that has stopped processing CI-V cannot be unkeyed over the network,
  which fits the dead carrier.
- Station A was still connected and keyed 31 more overs between 19:59:30 and
  20:03:21, until the test stations were shut down. The note written that night
  that nothing from AXTerm was connected was wrong. Any keying after about
  20:03:46 came from the hub or the radio, not from the Mac.
- CI-V to the 705 stayed dead from 20:05 until 04:18 on 2026-10-01, when the
  link came back and the radio confirmed it was not transmitting.

Transmit tail: about 300 ms comes from AXTerm sending trailing silence after the
frame (`LANModemAudioIO`), and about 340 ms from the hub waiting out an assumed
300 ms radio buffer plus 40 ms. With the radio really buffering around 100 ms,
that adds up to the measured 0.7 s.

Safeguards to put in place: the 705's own transmit time-out timer as the last
backstop; in Warbler, confirm the radio's real transmit state while idle and
unkey on disagreement, never resend a superseded key-down, drop an unconfirmed
key-down once an unkey is queued, and time the unkey from the last audible
sample; in AXTerm, stop sending trailing silence. Filing the Warbler items
needs a GitLab project token for `workshop/warbler`.

AXTerm's part is done (2026-10-01): when the far end is Warbler, the modem
sends no silence after the TXTAIL flags and unkeys as soon as the last
sample is handed over, leaving the hold to Warbler. A radio reached
directly keeps both. See "Transmit tail through Warbler" in
[SoundModem.md](SoundModem.md). Expect the carrier after each frame to
drop from about 0.7 s to about 0.25 to 0.4 s; confirm it on the air before
bringing B's TX delay down.
