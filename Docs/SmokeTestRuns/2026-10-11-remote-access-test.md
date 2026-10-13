# Remote access and today's fixes, test run 2026-10-11

On the air through Warbler. Steps 1 to 8 and 11 on 145.650 PKTFM, as the
constitution retest; steps 9 and 10 on 145.050 with the operator's LinBPQ test
node, whose logs Claude watches during them (operator, 2026-10-11). A (705) is
K0EPI-2 with the mailbox K0EPI-4; the iPad is K0EPI-3 on the ID-50 through the
TNC4. The operator moves both radios between the two frequencies; AXTerm does
not retune them.

The build is `9b25408b`. Before step 1, with the operator's go-ahead: A backed
up, quit from its menu and relaunched with `--keep-data`; the TNC4
disconnected on the iPad, then the iPad installed.

Record each step's result in the table at the end as it is run.

## The steps

### 1. Asking an AXTerm station about AXDP (findings 1 and 5)

- 1a. iPad: connect to K0EPI-4. Within a few seconds the badge in Send File
  reads AXDP and the Mailbox Area picker appears. (The iPad remembered the
  mailbox as "not AXDP"; its greeting says AXTerm, which outranks that.)
- 1b. On A's Packets page, the check is an AXDP PING inside the session (an
  I-frame), answered by a PONG the same way. No `AXDP?` UI frame.
- 1c. Disconnect and connect again. No PING or probe at all this time: the
  mailbox is remembered with its capabilities.

### 2. Asking a station that is not AXTerm

- 2a. iPad: connect to EPINOD. At most one `AXDP?` UI frame, sent right after
  the RR for the node's greeting, in the same transmission.
- 2b. Disconnect, connect again: no probe.
- 2c. Send File to EPINOD: the badge reads "No answer" with Check Again.
  Pressing it sends one probe.

### 3. Photos (finding 4)

- 3a. iPad, connected to K0EPI-4: Send File, pick a photo. The format picker
  shows a size on each choice ("JPEG · 21 KB", "HEIC · 11 KB"), and the line
  under the preview compares them. HEIC is smaller.
- 3b. Small, Medium, Large: the pixel size follows the choice. A detailed photo
  at Small may step down in size; the comparison line then gives JPEG's pixel
  size.
- 3c. Press and hold the preview: the original shows. The photo as sent looks
  right.

### 4. The iPad's history (finding 2)

- 4a. A sends the iPad a long plain-text message (AXDP off for the send, or to
  a session the iPad opened with AXDP off). The iPad's history follows the
  new lines without jumping up and back.

### 5. The mailbox from a plain terminal

- 5a. iPad at K0EPI-4: `H`. The help comes in pages of 24 lines with
  "-- n more lines: Enter for more, A to stop --". Enter shows the rest.
- 5b. `L` or a long `R n`, then `A` at the first page: it stops and the prompt
  comes back. Typing a command at a page prompt runs it.
- 5c. `OP 10`, then a long listing: pages of 10. `OP 0`: no pages. `OP` alone
  says which.
- 5d. `DB <a photo or other binary in a shared area>`: it says base64 and the
  time, then types the file. The iPad puts it in Transfers, and it opens.

### 6. Owner sign-in with a code

- 6a. A: Settings › BBS (mailbox settings), turn on "Sign in from the road with
  a one-time code", Set Up the Code, scan the QR code with an authenticator app
  on your phone.
- 6b. iPad at K0EPI-4 (K0EPI-3 is your callsign, so it may sign in):
  `OWNER <code>`. "Signed in as the owner". `ST` shows unread mail, callers in
  the last day and uploads waiting. A's call log says "signed in as the
  owner".
- 6c. Reconnect and type the same code again within the same 30 s: "already
  used".
- 6d. Three wrong codes: "Too many wrong codes"; the right one is refused for
  15 minutes. A's call log shows each.

### 7. Owner sign-in with the iPad's key

- 7a. iPad: mailbox settings, Copy This Device's Key. Send it to the Mac
  (AirDrop or Messages).
- 7b. A: mailbox settings, Add a Device, paste it, name it iPad.
- 7c. iPad at K0EPI-4: the key button (or Sign In as Owner in the menu). The
  terminal shows `OWNER KEY`, the challenge, then `OWNER SIG …`, then "Signed
  in as the owner". `ST` works.

### 8. Settings

- 8a. A: Settings › Packet Node. "On the air now" at the top matches what is
  running; NET/ROM Node, Mailbox and Ping each have a "Carried on" row; the
  IC-705 has its digipeater and ID beacon; the switched-off Direwolf radio is
  one line with Show Their Settings.
- 8b. File Transfers is its own page in the sidebar, with the auto-accept and
  auto-deny lists and the largest file.
- 8c. The same on the iPad (More, Settings).

### 9. AXDP through the LinBPQ node (145.050)

Both radios on 145.050. Claude follows the node's log for each step, so what
BPQ does with the relay (its "Connected to" wording, how it re-packs the
stream, whether it passes every byte) is seen, not assumed. Below, NODE is the
LinBPQ node's callsign.

- 9a. iPad: connect to NODE, type `C K0EPI-2`. The node says it connected; its
  log shows the downlink to K0EPI-2 and from which callsign.
- 9b. The iPad's Send File lists "K0EPI-2 via NODE" (not NODE itself) and its
  badge reads AXDP within a few seconds (A is remembered as AXTerm).
- 9c. Send a small photo by AXDP. A is offered it from K0EPI-3, not NODE.
  Accept: it arrives whole. The node's log shows the bytes passing through
  untouched.
- 9d. Type a line: A's terminal shows it as plain text.
- 9e. On A, NODE is not remembered as AXTerm (A's Packets show no PING to
  NODE, and a later direct connect from A to NODE sends no AXDP).
- 9f. Type `B` to the far end (or let A disconnect): back at the node. Send
  File no longer lists K0EPI-2.

### 10. AXDP over a NET/ROM circuit (145.050)

This makes A announce itself on 145.050, which writes it into the LinBPQ
node's table. Turn it off again at the end.

- 10a. A: Packet Node, Run the node on, Announce on, alias `AXTNOD`. Wait for
  a NODES broadcast; the LinBPQ log shows it learned AXTNOD.
- 10b. iPad: once it has heard A's NODES (directly, or the node's), connect
  bar in NET/ROM mode to K0EPI-2. A native circuit opens; A's node prompt
  appears. If the circuit goes through the LinBPQ node, its log shows the
  circuit and the L4 frames.
- 10c. With A remembered as AXTerm, the iPad's badge reads AXDP. A's log says
  the node let the circuit go to an AXDP conversation.
- 10d. Send File lists "K0EPI-2 over NET/ROM". Send a small photo by AXDP: A
  is offered it from K0EPI-3, and it arrives whole, in NET/ROM frames.
- 10e. A: Run the node and Announce back to how they were.

### 11. Nothing else changed

- 11a. iPad to the LinBPQ node: a plain session, commands and answers as
  usual, no stray binary (its log shows nothing it could not read).
- 11b. A YAPP send from the iPad to K0EPI-4 still works.
- 11c. A's APRS messaging and beacons as before (switch to APRS only if you
  want to, and back).

## Results

| Step | Result | Notes |
|---|---|---|
| 1a | Pass | |
| 1b | Pass | 69-byte PING and PONG as I-frames on A's Packets page |
| 1c | Pass? | Operator thinks so; hard to tell from the iPad |
| 2a | Unclear | Connected; hard to tell about the probe |
| 2b | Unclear | |
| 2c | Check | Badge turned AXDP after Check Again; confirm which station |
| 3a | Pass | |
| 3b | Pass | |
| 3c | Pass | |
| 4a | Pass | History followed the text |
| 5a | Pass | |
| 5b | Pass | |
| 5c | Pass | |
| 5d | Pass | |
| 6a | Done | |
| 6b | Pass | After reconnecting; the first try failed, see finding 8 |
| 6c | Pass | "already used" |
| 6d | Pass | |
| 7a | | |
| 7b | | |
| 7c | | |
| 8a | | |
| 8b | | |
| 8c | | |
| 9a | | |
| 9b | | |
| 9c | | |
| 9d | | |
| 9e | | |
| 9f | | |
| 10a | | |
| 10b | | |
| 10c | | |
| 10d | | |
| 10e | | |
| 11a | | |
| 11b | | |
| 11c | | |

## Findings

1. A crashed at 11:58:47 (17:58Z) after the constitution went to the iPad by
   AXDP. A click on a console row's empty space bounced between the row and
   the table until the stack ran out. Fixed in `4483544a`, with a test; A
   rebuilt and relaunched with `--keep-data` at 12:15, after a backup in
   `AXTerm-Backups/2026-10-11-1215-postcrash`.
2. After the crash, macOS reopened AXTerm without arguments: the normal app,
   on the real settings, not Station A. Quit from its menu at 12:14.
3. With K0EPI-4 gone, the iPad (K0EPI-3) kept polling it with RR and the
   poll bit about every 5 s for at least 6 minutes. The link should have
   given up after its retry limit. Needs the iPad's log.
4. The iPad's session history does not stay scrolled to the bottom (seen
   during step 2).

5. The Mac has no way to send plain text to a station confirmed as AXDP.
   The compose bar's AXDP button left in the February redesign (`d08542c5`,
   "pretty chin") and nothing replaced it; typed text uses AXDP whenever
   the other station is confirmed (`useAXDP` starts on and nothing turns it
   off). Found at step 4a. Fixed in `20f66fc5`: the switch is back, shown
   whenever typed text would go as AXDP. A rebuilt and relaunched with
   `--keep-data` at 12:33, after a backup in
   `AXTerm-Backups/2026-10-11-1232-axdpswitch`.
6. Pasted text loses its line breaks at the far end. A sends the pasted
   text's line breaks as LF (0x0A) and adds one CR at the very end; packet
   terminals end a line with CR. AXTerm's own receiver takes a lone LF as a
   line end but drops blank lines, so paragraphs run together (step 4a, the
   constitution: 81 frames with LF, one CR).
7. The sender cannot see what it is sending. A's session view fills with a
   row per I-frame, RR and "Frame sent successfully", so the message's own
   line scrolls out of sight within a few frames (step 4a).
8. Owner sign-in by code fails in a session that was already open when the
   code was set up. The mailbox decides at connect time whether `OWNER` is
   offered; the iPad connected at 12:33:55, before step 6a, so its session
   answers `? OWNER`. The iPad's line went as AXDP chat and the mailbox read
   it correctly, so the transport is fine.
9. A sent an empty carrier from about 13:11 to 13:2x: the 705 keyed for
   every reply, Warbler logged A's transmit audio as complete and on time,
   and the iPad decoded nothing (it took several tries to disconnect). The
   hub link to the 705 was uneven at 13:14. Working again by 13:29. Cause
   not found: Warbler counts audio packets, not their level.

