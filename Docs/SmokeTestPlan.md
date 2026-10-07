# AXTerm smoke test plan

**Plan version 3, 2026-10-07.** Version 3: adds 13.4, the iPad as B (ID-50)'s host. Version 2: 6.5 expects mailbox uploads by YAPP only.

This is the formal smoke test for AXTerm. It is run live on the air, the same
way every time, before a release and after any change to AX.25 or a service
built on it. It goes from a bare UI frame up through every service AXTerm
offers, each layer resting on the ones before it.

Each run is recorded in its own log in [SmokeTestRuns/](SmokeTestRuns/),
copied from [TEMPLATE.md](SmokeTestRuns/TEMPLATE.md). The log is updated after
every test, so a run can stop at any point and pick up later without losing
anything. See "Running the test" and "Stopping and resuming" below.

## The two stations

Always named by letter **and** radio, everywhere: in the plan, in run logs,
and when talking about a test.

| | **A (705)** | **B (ID-50)** |
|---|---|---|
| Radio | Icom IC-705, about 0.2 W | Icom ID-50, low power |
| How AXTerm reaches it | AXTerm's sound modem through Warbler (`localhost:50100`); rig control over the same link | Mobilinkd TNC4 over USB serial (Bluetooth only in test 9.3) |
| Callsign | K0EPI-2 | K0EPI-3 |
| TX delay | default | 800 ms |
| Frequency | 145.070 MHz FM simplex | same |
| Who changes its settings | Claude, through AXTerm's rig control | the operator, by hand |

Both stations are AXTerm test instances (`--test-mode`), each with its own
settings and databases under the app container's `tmp/AXTerm-Test/`. Test mode
wipes settings at every launch, so a relaunched station must be set up again
(steps S1 to S6).

## Who runs each test

| Mark | Meaning |
|---|---|
| **C** | Claude runs it alone: drives both test instances, reads their logs and packet databases, checks received files by SHA-256, and sets A (705) through AXTerm's rig control. |
| **Y** | Needs the operator. The test says what for: a radio knob, a password, a macOS prompt, or a decision. |
| **L** | Live against real stations beyond the two test stations (DRL, DRLNOD, KB5YZB-7, live APRS on 144.390). The operator picks when, and the radio, frequency and power. Claude runs it once set up. |

The Docker test rig (`TestRig/`) may rehearse a test off the air first. It
never replaces the live run.

## Rules for every run

1. Transmit only for these tests, on 145.070 at low power. NODES broadcasts,
   APRS and beacons from the test stations go out on 145.070, never 144.390.
   Test 4.6 listens on 144.390 and transmits nothing there.
2. Never save settings to the TNC4's memory. The TNC4 is shared with the
   ID-50's everyday use; AXTerm applies B (ID-50)'s settings while connected
   and puts the TNC4's own back on close.
3. When the run ends or stops for a long break, A (705) goes back to 144.390
   PKTFM at its usual power, and the operator puts B (ID-50) back on its usual
   channel.
4. Processes are ended by pid only, after listing them. Never by pattern.
5. A failed test is logged with its evidence, fixed test-first in the code,
   and re-run. It is never marked passed by hand.

## Test files

The same files every run, kept in [SmokeTestRuns/files/](SmokeTestRuns/files/)
with their SHA-256 sums (`SHA256SUMS`). Setup copies them to
`~/Downloads/AXTerm Smoke Files/`, where the sandboxed app can read them. A
received file passes only if its sum matches.

| Name | Contents |
|---|---|
| `t256_allbytes.bin` | 256 bytes, every byte value once |
| `t1k_bin.bin` | 1 KB random |
| `t3k_text.txt` | 3 KB text |
| `t20k_bin.bin` | 20 KB random |
| `photo.jpg` | a JPEG of about 10 KB, for Winlink |

## Running the test

1. **New run.** Copy `SmokeTestRuns/TEMPLATE.md` to
   `SmokeTestRuns/<date>-<n>.md` (for example `2026-10-03-1.md`). Fill in the
   header: plan version, commit and branch, start time. Commit it.
2. **Setup** (S1 to S6 below). Record the starting state of A (705) and the
   TNC4 in the log before anything transmits.
3. **Work the layers in order.** For each test: run it, then at once write
   its status, time and evidence in the log, and update the resume point.
4. **Commit the log** at the end of every layer, and at any stop.
5. **Finish** with the closing steps (E1 to E6), then fill in the summary.

### Status values

| Status | Meaning |
|---|---|
| `—` | not run yet |
| `PASS` | ran and met its pass condition |
| `FAIL` | did not; issue number in the notes |
| `RETEST PASS` | failed earlier in this run, fixed, and passed on re-run (commit in the notes) |
| `BLOCKED` | could not run (why, and what it waits for) |
| `SKIP` | left out on purpose (why, and who decided) |

## Stopping and resuming

The run log's **resume point** is the one place that says where a run stands.
It is rewritten after every test and holds:

- the next test to run;
- what is running: which instances, which links are up, what each station is
  doing (advertising NODES, beaconing, digipeating);
- the radios: A (705)'s frequency, mode and power; B (ID-50)'s channel as the
  operator last set it; Warbler transmit on or off;
- anything half done (a test interrupted partway is always re-run from its
  start; note what was seen).

**Short break** (minutes; the operator stays nearby): leave everything
running. Note the time in the resume point.

**Long break or end of day:** turn off NODES advertising, beacons and the
digipeater in both stations; close both instances; put A (705) back on
144.390 PKTFM; the operator puts B (ID-50) back on its usual channel and may
turn off Warbler transmit. Write all of that in the resume point, with
"setup needed" as the next step, and commit the log.

**Resuming:**

1. Open the newest log in `SmokeTestRuns/` and read its resume point.
2. If the commit under test has changed since the run started, note it. A
   change to AX.25 or a service means re-running the layers it touches (say
   which in the notes); otherwise carry on.
3. Check the stations really are as the resume point says. If an instance was
   closed or relaunched, run setup S1 to S6 again.
4. Re-run any test marked as interrupted, then continue from the next test.

## Setup

| Step | What | Who |
|---|---|---|
| S1 | Re-enable transmit for A (705) in Warbler | Y |
| S2 | Set B (ID-50) to 145.070 FM, low power, no tone, volume at the level that does not clip | Y |
| S3 | Quit the main AXTerm (or disconnect A (705) in it); close the Mobilinkd configuration app | Y |
| S4 | Build the commit under test; copy the test files to `~/Downloads/AXTerm Smoke Files/`; launch both test instances: A (705) from the Debug build, B (ID-50) from a copy with its own bundle ID (`com.rosswardrup.AXTerm.stationb`) so the two never share settings, each with `--test-mode --instance-name "Station A"` or `"Station B"`; answer Warbler's password and macOS prompts (microphone, keychain) | C, Y for prompts |
| S5 | Configure A (705): K0EPI-2, Warbler at `localhost:50100`. Configure B (ID-50): K0EPI-3, TNC4 on USB with the Mobilinkd switch on, TX delay 800 ms | C |
| S6 | Record the starting state: A (705)'s frequency, mode and power, then set it to 145.070 FM at about 0.2 W; the TNC4's settings as B (ID-50) finds them | C |

## Tests

### 0. Baseline

| ID | Test | Pass | Who |
|---|---|---|---|
| 0.1 | A (705) sends a UI frame, B (ID-50) decodes it; then B (ID-50) to A (705) | both directions decoded, no decode errors | C |
| 0.2 | Receive levels on A (705) and B (ID-50) | inside the green range, no clipping | C |

### 1. AX.25 connected mode

| ID | Test | Pass | Who |
|---|---|---|---|
| 1.1 | A (705) connects to B (ID-50) | XID offers 256-byte frames and window 4; the UA's F bit equals the SABM's P bit | C |
| 1.2 | Chat both ways, including a line longer than one frame | every line arrives once, in order, at both stations | C |
| 1.3 | Leave the link idle until T3 polls | link stays up; one poll and answer per T3, no poll storm | C |
| 1.4 | A (705) disconnects | DISC and UA; both show disconnected; no stray frames after | C |
| 1.5 | B (ID-50) connects to A (705), chats, and disconnects from B (ID-50)'s side | as 1.1 to 1.4 the other way | C |
| 1.6 | A (705) connects while B (ID-50) is transmitting | connect completes after retries; one session only | C |

### 2. AXDP

| ID | Test | Pass | Who |
|---|---|---|---|
| 2.1 | Capability check after A (705) connects to B (ID-50) | PING/PONG; AXDP badge on both | C |
| 2.2 | AXDP chat both ways | delivered once, in order | C |
| 2.3 | Disconnect, reconnect | capability found again on the new link | C |

### 3. File transfers

| ID | Test | Pass | Who |
|---|---|---|---|
| 3.1 | AXDP A (705) to B (ID-50): `t256_allbytes.bin`, then `t20k_bin.bin` | sums match; both stations "completed" | C |
| 3.2 | AXDP B (ID-50) to A (705): `t1k_bin.bin` with compression off, LZ4, deflate | sums match each time | C |
| 3.3 | A second session to B (ID-50) after 3.1, with a transfer | window and frame size grow during the session, never below the learned start | C |
| 3.4 | YAPP A (705) to B (ID-50): `t3k_text.txt`; YAPP B (ID-50) to A (705): `t1k_bin.bin` | sums match | C |
| 3.5 | Cancel early from the sender, then from the receiver, for AXDP and for YAPP | both stations canceled; nothing left "busy" | C |
| 3.6 | YAPP canceled near the end, after the receiver has the file (bug 49) | the transfer finishes; no stray text on the other station | C |
| 3.7 | Another YAPP straight after a cancel | starts within a few seconds | C |
| 3.8 | B (ID-50) declines an offer from A (705) | A (705) shows declined; B (ID-50) canceled | C |
| 3.9 | Pause and resume an AXDP transfer from A (705) | sum matches after resume | C |
| 3.10 | Auto-accept on B (ID-50) from its allow list, its terminal not on screen | accepted, saved, notified | C |

### 4. APRS

| ID | Test | Pass | Who |
|---|---|---|---|
| 4.1 | Position beacon from A (705) and from B (ID-50), on 145.070 | each decoded and placed correctly by the other | C |
| 4.2 | APRS message A (705) to B (ID-50) with ack, and B (ID-50) to A (705) | delivered once, acked, no repeats after the ack | C |
| 4.3 | A (705) places, moves and kills an object | B (ID-50) follows each change | C |
| 4.4 | Bulletin, weather report and telemetry from A (705) | decoded and shown on B (ID-50) | C |
| 4.5 | Directed query and ping/reachability probe, each way | answered; the answer attributed to the right station | C |
| 4.6 | A (705) listens on 144.390 for 15 minutes, receive only | positions, Mic-E, weather, objects, telemetry and messages decoded without errors and placed correctly; nothing transmitted | L |

### 5. Winlink

| ID | Test | Pass | Who |
|---|---|---|---|
| 5.1 | Peer-to-peer: A (705) calls B (ID-50); one message each way | both delivered, identical | C |
| 5.2 | Peer-to-peer with `photo.jpg` attached, A (705) to B (ID-50) | photo byte-identical to the copy A (705) stored | C |
| 5.3 | A (705) has no mail for B (ID-50); B (ID-50) has mail for A (705) (bug 50) | B (ID-50)'s mail arrives | C |
| 5.4 | Abort on A (705) while preparing, while connecting, and mid-exchange (bugs 45, 46) | each ends as aborted; nothing stuck "sending" | C |
| 5.5 | Mail to a third call stays queued in a peer-to-peer exchange | not sent | C |
| 5.6 | A (705) through a real RMS gateway on RF | mail to and from CMS. Needs a gateway in range and the Winlink password | Y |
| 5.7 | Telnet to CMS | same. The operator types the password | Y |
| 5.8 | A form composed on A (705), sent peer-to-peer; ICS-309 log | form opens on B (ID-50); ICS-309 lists the exchange | C |

### 6. Mailbox (B (ID-50)'s BBS)

| ID | Test | Pass | Who |
|---|---|---|---|
| 6.1 | A (705) connects to B (ID-50)'s mailbox; first-call questions | greeted, questions skippable, prompt | C |
| 6.2 | A (705) sends a message, lists, reads | stored once, listed, body whole | C |
| 6.3 | A (705) kills a private message it sent to the sysop (bug 52) | killed; still not readable by A (705) | C |
| 6.4 | Files: list areas, text download, binary download by YAPP | text typed out; binary sum matches | C |
| 6.5 | A (705) uploads a file to the mailbox by YAPP; an AXDP offer during `U` is declined with a message saying YAPP | the YAPP upload is stored and listed on B (ID-50); the AXDP offer is declined and says why | C |
| 6.6 | Directory (white pages) | entries learned and shown | C |
| 6.7 | Refusals: a call to the wrong callsign; a second caller while busy | refused with the right reason | C |

### 7. NET/ROM

Nobody nearby broadcasts NODES, so the two test stations do it themselves.

| ID | Test | Pass | Who |
|---|---|---|---|
| 7.1 | A (705) advertises as EPINDA, B (ID-50) as EPINDB, broadcasting every few minutes | each learns the other's route from NODES | C |
| 7.2 | A (705) opens a NET/ROM circuit to EPINDB | CONREQ and CONACK; data both ways | C |
| 7.3 | A (705) connects to EPINDB over plain AX.25 and walks NODES, ROUTES, MH, INFO, BYE | each answered with the prompt; BYE hangs up | C |
| 7.4 | From B (ID-50)'s node, `BBS` | B (ID-50)'s mailbox answers over the node | C |
| 7.5 | From B (ID-50)'s node, connect onward to a call that is not on the air | A (705) back at the node prompt | C |
| 7.6 | A (705) connects to KB5YZB-7 (a real BPQ node) through DRL and walks NODES, ROUTES | answers arrive whole; the scraped routes reach A (705)'s Nodes page | L |
| 7.7 | Advertising off on both | no more NODES broadcasts | C |

### 8. Digipeating and paths

| ID | Test | Pass | Who |
|---|---|---|---|
| 8.1 | A (705) digipeats: B (ID-50) sends a UI frame via K0EPI-2 | A (705) repeats it with the H bit set; B (ID-50) hears its own frame repeated | C |
| 8.2 | A (705) connects through DRL to DRLNOD's node or KB5YZB-7 | session up through the digipeater, data both ways, path shown | L |

### 9. Radio, TNC and modem

| ID | Test | Pass | Who |
|---|---|---|---|
| 9.1 | A (705)'s rig control: set for packet, restored on close | frequency, mode and power after close equal those recorded in S6 | C |
| 9.2 | B (ID-50)'s TNC4 profile applied on connect, restored on close | TNC4 values after close equal those in S6; nothing saved to its memory | C |
| 9.3 | B (ID-50) with the TNC4 over Bluetooth: repeat 3.1 and 3.4 | all pass; TNC4 settings restored. Needs the TNC4 unplugged from USB data (it takes one host at a time) and pairing | Y |
| 9.4 | TNC4 test tones on B (ID-50), low power on 145.070 | keys, stops when told, radio unkeyed after | C |
| 9.5 | Receive-level assistant on B (ID-50), using its own beacons and decode rates | settles on a level; nothing saved to the TNC4 | C |
| 9.6 | Link dropped mid-transfer: the operator switches B (ID-50) off | both stations fail cleanly within N2; nothing stuck | Y to switch, C to check |
| 9.7 | Beacons on A (705) and B (ID-50) | sent on interval, decoded by the other | C |

### 10. Terminal and sessions

| ID | Test | Pass | Who |
|---|---|---|---|
| 10.1 | Line mode and raw mode on A (705) | typed text and echo as set | C |
| 10.2 | Capture received text to a file; text download capture | file holds exactly what arrived | C |
| 10.3 | Session history: list, open, replay a finished session | matches what happened | C |
| 10.4 | A session survives an app restart (CLAUDE.md §5) | after relaunch the session and its history are there. Test mode wipes settings at launch, so this may need the main app | C, Y if the main app |
| 10.5 | Idle session A (705) to B (ID-50), 10 to 15 minutes | stays up; polling as expected; no gap-chase or poll loops | C |

### 11. Adaptive behavior

| ID | Test | Pass | Who |
|---|---|---|---|
| 11.1 | What one session learns carries into the next to the same station | start values match what was learned | C |
| 11.2 | Same after an app restart | as 11.1, subject to 10.4 | C |
| 11.3 | Turnaround loss hint | shown when answers keep arriving while still keyed, and explained in its tooltip | C |

### 12. Specific fixes

Kept in the plan as regression checks; each names the bug it guards.

| ID | Test | Pass | Who |
|---|---|---|---|
| 12.1 | Bug 47: a lost reply at the end of a transfer is resent (watched for during layer 3) | no transfer hangs at the end | C |
| 12.2 | Bug 53: A (705) sends a YAPP start with no header, then chat | chat arrives at B (ID-50); no "not YAPP" text on A (705) | C |
| 12.3 | Bug 48: no endless gap polling over a long session (watched for in 10.5) | none seen; any data-loss event in the logs reported | C |
| 12.4 | RR-poll change (dc29aaa): A (705) connects to DRLNOD, sends `Help`, stays a few minutes; then KB5YZB-7 through DRL | no DM after a poll; no duplicate resends; everything delivered | L |
| 12.5 | Layer 3 again with AXDP turned off in both stations | YAPP everywhere; all pass | C |

### 13. Other checks

| ID | Test | Pass | Who |
|---|---|---|---|
| 13.1 | Callsign lookup, elevation downloads, solar conditions | data arrives and is shown | C (needs internet) |
| 13.2 | Network graph and link metrics (df, dr, ETX, quality) after a long session | values and tooltips make sense | C, with Y to look |
| 13.3 | The iPhone as B (ID-50)'s host, TNC4 over Bluetooth: repeat layers 1 to 3 against A (705) | as in 1 to 3 | Y for the iPhone, C to check A (705) |
| 13.4 | The iPad as B (ID-50)'s host, TNC4 over Bluetooth: 1.1, 1.2, 1.4, 1.5, 2.1, 3.1 (`t3k_text.txt` only), 3.4, one 3.5 cancel each way, 3.8; then the layout full screen in portrait and landscape and in Split View at its narrowest; then leave the app with a link up | as in 1 to 3; no control clipped or overlapping at any width, the narrow layout matches the iPhone's; leaving the app sends DISC and UA ends the link | Y to tap on the iPad, C to drive A (705) and check |

## Closing steps

| Step | What | Who |
|---|---|---|
| E1 | NODES advertising, beacons and the digipeater off in both stations | C |
| E2 | Both instances closed; the TNC4's settings compared with S6 | C |
| E3 | A (705) back to 144.390 PKTFM at its usual power; compared with S6 | C |
| E4 | B (ID-50) back to its usual channel | Y |
| E5 | Warbler transmit for A (705) off, if the operator wants it off | Y |
| E6 | Log summary filled in, issues listed, log committed | C |

## Changing this plan

The plan is versioned. A test ID is never renumbered or reused, so results
from different runs line up. New tests get the next free number in their
layer; a retired test is struck through and left in place. Every change bumps
the version at the top and says why in the commit.
