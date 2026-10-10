# Home retest after the park test, 2026-10-10

A (705) on `a3a2b530`, 145.650 PKTFM through Warbler, mailbox K0EPI-4. The
iPad on the same build with the TNC4 and the ID-50 as K0EPI-3, at home. The
script is the one written in the session after the park test: A, A stays up
(the console crash fixes); B, mailbox uploads with uploads off; C, uploads on;
D, the station itself; E, APRS settings on a packet radio.

## Why this run

At the park (16:33Z to 16:53Z) the iPad's uploads to K0EPI-4 were refused,
and A then quit at 16:53:09Z. Three causes, fixed before this run:

- The new AppKit console set a row's text view text while the table built the
  row; an accessibility client (Magnet, AltTab) asked for the table's rows in
  the middle of it and NSTableView threw (`fc2e10f8`).
- Measuring an empty console message asked an empty string for its font at
  index 0. The YAPP bytes from the park left empty lines in A's history, so A
  crashed on every launch afterward (`a3a2b530`).
- The mailbox read a YAPP send-init without `U` as half a command, and told an
  AXDP offer to use YAPP although uploads were off (`0899c714`).

## Summary

Everything A (705) does held up: no crash all run, the console scrolled and
selected cleanly, the mailbox refused uploads correctly with uploads off and
took a YAPP upload without `U` with them on, and the photo to K0EPI-2 and the
text download from PARK both completed. The iPad turned up the failures: it
drops a line of text that follows an AXDP message (B1), and it reports an
APRS message it never sent as sent (E3). Fourteen findings, none fixed yet.

## Results

| Step | Result | Notes |
|---|---|---|
| A1 W PARK, A's console shows the session | Pass | |
| A2 scroll A's Terminal | Pass | New-lines pill shows |
| A3 select text, Copy | Pass | |
| A4 click a callsign link | Pass | |
| B1 photo by AXDP to K0EPI-4, uploads off | Fail (iPad) | Declined at once with the right reason on the air (18:49:35Z); the iPad dropped the reason line. Finding 1 |
| B2 YAPP without `U`, uploads off | Pass | Reason shown in the terminal and in Transfers |
| B3 `W` after the refusals | Pass | |
| C1 uploads on | Done | The switch is in the BBS window under Files, not Settings › BBS |
| C2 YAPP without `U`, uploads on | Pass | First attempt went as AXDP and was declined with "YAPP only" (18:56:00Z), as C4 expects. By YAPP: "Received Photo-20261010-125639.jpg (10K)", saved to ~/Documents/docs |
| C3 `U` then YAPP | Skipped | Works, but on the iPad it means typing `U` in the terminal and then switching to Transfers to start YAPP. Since the send-init now starts an upload, an AXTerm caller has no need of `U`; it stays for other software. The unit tests cover it |
| C4 AXDP to K0EPI-4, uploads on | Pass | Declined "YAPP only, send it again with YAPP" (18:56:00Z and again at 19:05:21Z for t1k_bin.bin) |
| C5 log off | Pass | |
| D1 photo by AXDP to K0EPI-2 | Pass | No Accept prompt on A (K0EPI-3 is always accepted). Typing `U` to K0EPI-2 first did nothing, as it should: K0EPI-2 is A's terminal, not the mailbox |
| D2 `W PARK`, download cheat-sheet.txt | Pass | Arrived and was saved to Transfers, but streamed into the terminal as text first (text under 8 KB goes as text, by design). Finding 12 |
| E1 Packet Node digipeater shows only its switch and aliases | Pass | |
| E2 empty ID beacon shows a note and a suggestion | Pass | The Use This button looks like the grey caption around it. Finding 13 |
| E3 APRS message from the iPad on Packet | Fail (display) | Nothing transmitted (A heard no APRS frame from K0EPI-3 after 19:12:30Z), but the message showed "Sent · awaiting ack #1". Finding 14 |

## Findings

1. **Text right after an AXDP message is dropped.** The terminal sets a flag
   to suppress the raw bytes of an I-frame that completed an AXDP message, and
   clears it asynchronously. When AX.25 delivers the next I-frame in the same
   pass (here a frame held out of order, released when the REJ'd frame came
   back), its text is suppressed too. Fix: the reassembler returns AXDP
   messages and plain text separately, and the terminal is given only the
   text. Affects the Mac and iOS.
2. **The iPad's TNC4 connect waits forever.** The iPhone held the TNC4 (it took
   it 5 s after the iPad let go, 18:39:20Z) and the iPad showed "connecting"
   with no explanation. Fix: after a set wait, say the TNC4 is not answering
   and may be connected to another device.
3. **The iPhone reconnects to the TNC4 in the background for over an hour**
   (17:20:52Z to 18:39:20Z) and takes it the moment it is free. Fix: give up
   after a while, or at least notify when it reconnects.
4. **No progress while a long AXDP message arrives.** A large block of text
   from A appeared on the iPad only when complete, with nothing shown while it
   arrived. Fix: a "Receiving a message from …" row with bytes so far,
   replaced by the text; and a message that stops partway says so.
5. **Re-send a transfer from the transfer list**, after a confirmation prompt.
   Operator request during this run.
6. **The AXDP capability exchange takes two round trips** (probe, pong, ping,
   pong). A could answer the text probe with a PING so it takes three frames.
   Optional.
7. **AXDP uploads to the mailbox.** The mailbox takes uploads by YAPP only,
   because AXTerm's AXDP receiver cannot run on a session the mailbox owns.
   Proposed: give the mailbox its own AXDP receiver so an AXTerm caller can
   upload from Transfers. Waits for the operator's approval (it reverses
   `Docs/PacketBBS.md` §14's decision).
8. **Uploads are not listed in the BBS window.** It shows only "docs · 2 files";
   finding and opening an upload took Finder. Proposed: an uploads list that
   updates the moment a file is saved, with name, size, Received (date and
   time) and From (the caller's callsign), and Open, Quick Look, Show in
   Finder, Move to Area… and Delete (to the Trash, confirmed). Shared areas
   gain a Modified column. Needs the mailbox to record the caller per upload.
   Same list on iPad and iPhone, shaped for touch.
9. **False "Off air" in the BBS header.** `BBSService.currentRefusal` asks
   whether the mailbox would answer a call on `.primary`. On A that is the
   disabled network radio, which has the mailbox off, so the header said
   "Switched on, but not answering … the mailbox is switched off on the radio
   this call came in on" while the mailbox answered on the IC-705. It should
   ask whether any enabled radio answers mailbox calls.
10. **Offer "Send with YAPP instead" when a mailbox declines an AXDP offer
    for YAPP only.** The iPad's transfer row says only "Declined"; the reason
    is in the terminal (when finding 1 does not drop it). One tap should send
    the same file again by YAPP. Smaller than finding 7, and still useful for
    a mailbox that is not AXTerm.
11. **Trusted callers may upload straight to an area.** Uploads stay in the
    inbox by default, since anything in an area is served unattended under the
    operator's callsign. Proposed: a trusted-callers list (the operator's own
    callsigns to start) and a per-area "Trusted callers may upload here"
    switch, off by default. A trusted caller names the area before the upload
    (`U PARK`, or an area picker in AXTerm's Transfers); everyone else lands in
    the inbox and is told so. Waits for the operator's approval.
12. **A text download should look like a file transfer.** The mailbox sends a
    text file under 8 KB as plain text, which suits every caller. An AXTerm
    caller that asked for it with `D` knows a download is coming (the
    mailbox announces it), so it could open a Transfers row with name, size
    and progress, show one "Receiving cheat-sheet.txt… 40%" line instead of
    the whole file in the terminal, and finish with the banner and the saved
    file as now. Other software still gets plain text.
13. **"Use This" on the ID beacon suggestion does not look clickable.** A
    borderless small button inside a secondary caption reads as more caption.
    Make it a bordered small button at the trailing edge of the row, with the
    note in secondary text beside it, as the HIG asks for an inline action in
    a settings row.
14. **An APRS message blocked on a packet radio shows "Sent".** Since
    `4d5f1555` nothing APRS leaves a radio on Packet, and nothing did, but the
    message screen marks the message sent and awaiting an ack, and will retry
    it silently. With no radio on APRS, Messages should not offer to send at
    all: New message, New bulletin, Who can hear me? and the send button are
    disabled, and a note says no radio is set to APRS, with a Switch to APRS
    button (the mirror of the Terminal's Switch to Packet; a choice with
    several radios). Past conversations stay readable. A message caught by a
    radio switched to Packet while it waits for its ack is marked Not sent,
    with the reason, instead of retrying silently.

