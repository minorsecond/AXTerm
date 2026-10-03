# On-air test plan

The full smoke test for AXTerm, from bare AX.25 up to every service that rides
on it. Work it top to bottom: each layer assumes the ones before it passed.
Record each run in a dated log (`Docs/LiveRFTest-<date>.md`), one row per test
ID, with the commit the stations were built from.

Written 2026-10-03, after the full-stack fuzzing round (bugs 47 to 53 in
[LiveRFTest-2026-09-30.md](LiveRFTest-2026-09-30.md)) changed the AX.25 layer
itself, which is why the plan starts again from the bottom.

## Who does what

Each test is marked with who runs it. Every test runs live, on the TNC4 and
ID-50 and on the 705 through Warbler: the point is to know AXTerm works on
the air, not just in a simulator. The Docker test rig (`TestRig/`, LinBPQ
nodes on a simulated channel) can rehearse a test off the air first, but it
never stands in for the live run.

| Mark | Meaning |
|---|---|
| **C** | Claude runs it alone over the radio harness: drives both test instances on screen, reads their logs and packet databases, checks received files by SHA-256, and controls the 705 through AXTerm's rig control. |
| **Y** | Needs the operator. The test says exactly what for (a radio knob, a password, a macOS prompt, a decision). |
| **L** | Live on the air against real stations beyond the harness (DRL, KB5YZB-7, live APRS on 144.390). The operator picks when, and the radio, frequency and power; Claude runs the test once set up. |

## The harness

| | Station A | Station B |
|---|---|---|
| Callsign | K0EPI-2 | K0EPI-3 |
| Radio | IC-705, about 0.2 W | ID-50, low power |
| TNC | AXTerm's sound modem through Warbler (`localhost:50100`) | Mobilinkd TNC4 over USB (Bluetooth in 7.3) |
| TX delay | default | 800 ms |
| Frequency | 145.070 MHz FM simplex | same |

Both run as test instances (`--test-mode`, separate settings and databases
under the app container's `tmp/AXTerm-Test/`). Test mode wipes settings at
each launch, so a relaunch means setting the radio up again. Test files, with
SHA-256 sums: 256 bytes of every byte value, 1 KB random, 3 KB text, 20 KB
random, and one JPEG photo for Winlink.

Rules that hold for every test:

- Transmit only for these tests, on 145.070 at low power. NODES broadcasts,
  APRS and beacons in this plan go out on 145.070 too, never on 144.390.
- Never save settings to the TNC4's memory. The TNC4 is shared with the
  ID-50's everyday use; AXTerm applies settings per radio and puts them back
  on close.
- Afterwards the 705 goes back to 144.390 PKTFM at its usual power (C), and
  the ID-50 to its usual channel (Y).
- Processes are ended by pid only, after listing them; never by pattern.

## Before starting (Y)

1. Re-enable transmit for the 705 in Warbler.
2. Set the ID-50 to 145.070 FM, low power, no tone, volume at the level that
   stopped the clipping.
3. Quit the main AXTerm (or disconnect the 705 in it) and close the Mobilinkd
   configuration app.
4. Be at the keyboard for the first few minutes: Warbler's password and any
   macOS prompts (microphone, keychain) are yours to answer.

Then Claude (C): builds the commit under test, launches both instances, sets
up the radios, puts the 705 on 145.070 FM at about 0.2 W, and records the
starting state of the 705 and the TNC4 to check they are restored at the end.

## 0. Baseline

| ID | Test | Pass | Who |
|---|---|---|---|
| 0.1 | Each station sends a UI frame; the other decodes it | both directions decoded, no decode errors | C |
| 0.2 | Receive levels on both stations | inside the green range; no clipping | C |

## 1. AX.25 connected mode

| ID | Test | Pass | Who |
|---|---|---|---|
| 1.1 | A connects to B | XID exchanged, offering 256-byte frames and window 4; UA's F bit equals the SABM's P bit | C |
| 1.2 | Chat both ways, including a line longer than one frame | every line once, in order, both ends | C |
| 1.3 | Leave the link idle until T3 polls | link stays up; one poll and answer per T3, no poll storm | C |
| 1.4 | A disconnects | DISC/UA, both show disconnected, no stray frames after | C |
| 1.5 | B connects to A and disconnects from B's side | same as 1.1 to 1.4 in the other direction | C |
| 1.6 | Connect while the other station is busy transmitting | connect completes after its retries, no duplicate sessions | C |

## 2. AXDP

| ID | Test | Pass | Who |
|---|---|---|---|
| 2.1 | Capability check after connect | PING/PONG, AXDP badge on both | C |
| 2.2 | AXDP chat both ways | delivered once, in order | C |
| 2.3 | Reconnect after a disconnect | capability found again on the new link | C |

## 3. File transfers

| ID | Test | Pass | Who |
|---|---|---|---|
| 3.1 | AXDP A to B, 256 bytes and 20 KB | byte-identical; both ends "completed" | C |
| 3.2 | AXDP B to A, 1 KB, compression off, LZ4 and deflate | byte-identical each time | C |
| 3.3 | Second session after 3.1 | window and frame size grow during the session; never below the learned start | C |
| 3.4 | YAPP A to B, 3 KB text; YAPP B to A, 1 KB | byte-identical | C |
| 3.5 | Cancel from the sender early, and from the receiver early (AXDP and YAPP) | both ends canceled; nothing left "busy" | C |
| 3.6 | Cancel YAPP near the end, after the receiver has the file (bug 49) | transfer finishes; no stray text on the other terminal | C |
| 3.7 | Another YAPP straight after a cancel | starts within a few seconds | C |
| 3.8 | Decline an offer | sender says declined; receiver canceled | C |
| 3.9 | Pause and resume an AXDP transfer | byte-identical after resume | C |
| 3.10 | Auto-accept from the allow list with the terminal not on screen | accepted, saved, notified | C |

## 4. APRS (on 145.070)

| ID | Test | Pass | Who |
|---|---|---|---|
| 4.1 | Position beacon each way | decoded, placed on the map at the right spot | C |
| 4.2 | Message A to B with ack, and B to A | delivered once, acked, no repeats after the ack | C |
| 4.3 | Object placed, moved, killed | the other station follows each change | C |
| 4.4 | Bulletin, weather report, telemetry | decoded and shown | C |
| 4.5 | Directed query and ping/reachability probe | answered; the answer is attributed correctly | C |
| 4.6 | Live APRS, receive only: the 705 listens on 144.390 for 15 minutes (AXTerm sends no Mic-E and the radios do no AFSK APRS themselves, but the live channel is full of it) | positions, Mic-E, weather, objects, telemetry and messages decoded without errors and placed correctly; nothing transmitted | L |

## 5. Winlink

| ID | Test | Pass | Who |
|---|---|---|---|
| 5.1 | Peer-to-peer, A calls B, one message each way | both delivered, identical | C |
| 5.2 | Peer-to-peer with a photo attachment | photo byte-identical to what was stored | C |
| 5.3 | Caller has no mail, the answering side does (bug 50) | the answering side's mail arrives | C |
| 5.4 | Abort while preparing, while connecting, and mid-exchange (bugs 45, 46) | each ends as aborted; nothing stuck "sending" | C |
| 5.5 | Mail to someone else stays queued in a P2P exchange | not sent | C |
| 5.6 | Through a real RMS gateway on RF | mail to and from CMS; needs a gateway in range and the Winlink password | Y |
| 5.7 | Over telnet to CMS | same; the password is typed by the operator | Y |
| 5.8 | Forms and the ICS-309 log | a form composed, sent P2P, opened at the other end; ICS-309 lists the exchange | C |

## 6. Mailbox (B's BBS)

| ID | Test | Pass | Who |
|---|---|---|---|
| 6.1 | A connects; first-call questions | greeted, questions skippable, prompt | C |
| 6.2 | Send a message, list, read | stored once, listed, body whole | C |
| 6.3 | Kill a private message A sent to the sysop (bug 52) | killed; still not readable by A | C |
| 6.4 | Files: list areas, text download, binary download by YAPP | text typed out; binary byte-identical | C |
| 6.5 | Upload by YAPP and by AXDP | stored, listed | C |
| 6.6 | Directory (white pages) | entries learned and shown | C |
| 6.7 | Refusals: wrong callsign, a second caller while busy | refused with the right reason | C |

## 7. NET/ROM

Nobody nearby broadcasts NODES, so both test stations do it themselves.

| ID | Test | Pass | Who |
|---|---|---|---|
| 7.1 | Both stations advertise themselves (aliases EPINDA and EPINDB), broadcasts every few minutes | each learns the other's route from NODES | C |
| 7.2 | A opens a NET/ROM circuit to B's alias | CONREQ/CONACK; data both ways over the circuit | C |
| 7.3 | Node shell over plain AX.25: A connects to B's alias, walks NODES, ROUTES, MH, INFO, BYE | each answered with the prompt; BYE hangs up | C |
| 7.4 | From B's node, `BBS` into B's mailbox | the mailbox answers over the node | C |
| 7.5 | Connect onward through B's node to a station that is not there | caller returned to the prompt | C |
| 7.6 | Against a real BPQ node: connect to KB5YZB-7 through DRL, walk `NODES` and `ROUTES` | answers arrive whole; the routes AXTerm scrapes reach the Nodes page | L |
| 7.7 | Turn advertising off at the end | no more NODES broadcasts | C |

## 8. Digipeating and paths

| ID | Test | Pass | Who |
|---|---|---|---|
| 8.1 | A as digipeater: B sends a UI frame via K0EPI-2 | A repeats it with the H bit set; B hears its own frame repeated | C |
| 8.2 | Connected mode through a real digipeater: A connects through DRL (to DRLNOD's node or KB5YZB-7) | session up through the digipeater, data both ways, the path shown | L |

## 9. Radio, TNC and modem

| ID | Test | Pass | Who |
|---|---|---|---|
| 9.1 | Rig control: AXTerm sets the 705 for packet and puts it back on close | frequency, mode and power after close equal what was recorded before | C |
| 9.2 | TNC4 settings: B applies its profile on connect and restores on close | TNC4 values after close equal those before; no save to its memory | C |
| 9.3 | TNC4 over Bluetooth: same transfers as 3.1 and 3.4 | all pass; settings restored on close. Needs the TNC4 unplugged from USB data (the firmware takes one host at a time) and pairing | Y |
| 9.4 | TNC4 test tones (transmit, low power on 145.070) | tone keys, stops when told, radio unkeyed after | C |
| 9.5 | Receive-level assistant, using our own beacons and decode rates | settles on a level; nothing saved to the TNC4 | C |
| 9.6 | Link dropped mid-transfer: ID-50 switched off | both ends fail cleanly within N2; nothing stuck | Y (switch off), C (checks) |
| 9.7 | Beacons on each radio | sent at the set interval, decoded by the other | C |

## 10. Terminal and sessions

| ID | Test | Pass | Who |
|---|---|---|---|
| 10.1 | Line mode and raw mode | typed text and echo as set | C |
| 10.2 | Capture received text to a file; text download capture | file holds exactly what arrived | C |
| 10.3 | Session history: list, open, replay a finished session | matches what happened | C |
| 10.4 | Session survives an app restart (CLAUDE.md §5) | after relaunch the session and its history are there. Test mode wipes settings at launch, so this may need the main app | C, or Y if the main app |
| 10.5 | Long idle session, 10 to 15 minutes | stays up; polling as expected; no gap-chase or poll loops | C |

## 11. Adaptive behavior

| ID | Test | Pass | Who |
|---|---|---|---|
| 11.1 | What one session learns carries into the next to the same station | start values match what was learned | C |
| 11.2 | Same after an app restart | as 11.1, subject to 10.4 | C |
| 11.3 | Turnaround loss hint | shown when answers keep arriving while still keyed; explained in its tooltip | C |

## 12. Specific fixes to confirm on the air

| ID | Test | Pass | Who |
|---|---|---|---|
| 12.1 | Bug 47: a lost reply at the end of a transfer is resent (watch for it in 3.x) | no transfer hangs at the end | C |
| 12.2 | Bug 53: YAPP start with no header, then chat | chat arrives; no "not YAPP" text on the other terminal | C |
| 12.3 | Bug 48: no endless gap polling over a long session | none seen; any data-loss event in the log is reported | C |
| 12.4 | RR-poll change (dc29aaa) against DRLNOD: connect, send `Help`, keep the session a few minutes, then the same with KB5YZB-7 through DRL | no DM after a poll; no duplicate resends; everything delivered | L |
| 12.6 | Everything in 3 again with AXDP turned off | YAPP everywhere, all pass | C |

## 13. Other checks

| ID | Test | Who |
|---|---|---|
| 13.1 | Callsign lookup, elevation downloads, solar conditions | C (needs internet) |
| 13.2 | Network graph and link metrics (df, dr, ETX, quality) after a long session: values and tooltips make sense | C, with Y to look |
| 13.3 | iOS app on the air: the iPhone as station B with the TNC4 over Bluetooth, repeating 1 to 3 against A | as in 1 to 3 | Y (iPhone), C (checks on A) |

## At the end (C, then Y)

1. Advertising, beacons and the digipeater off in both instances.
2. Both instances closed; the TNC4 settings and the 705's settings compared
   with the starting values.
3. The 705 back to 144.390 PKTFM at its usual power (C).
4. The ID-50 back to its usual channel (Y).
5. Results logged; bugs filed in the log's table and fixed test-first.

## What the operator does, in one list

In order of appearance:

1. Before starting: re-enable 705 transmit in Warbler; ID-50 to 145.070 low
   power; quit the main AXTerm; close the Mobilinkd app; answer Warbler's
   password and macOS prompts.
2. The live tests marked L (4.6, 7.6, 8.2, 12.4): pick when, and the radio,
   frequency and power for reaching DRL, DRLNOD and KB5YZB-7, and for
   listening on 144.390.
3. 5.6 and 5.7: the Winlink password, and a gateway in range for 5.6.
4. 9.3: unplug the TNC4's USB data and pair it over Bluetooth.
5. 9.6: switch the ID-50 off mid-transfer when asked, then back on.
6. 10.4 and 11.2: possibly run the main app for the restart test.
7. 13.2: look over the graph and metrics; 13.3: the iPhone as station B.
8. At the end: the ID-50 back to its usual channel.
