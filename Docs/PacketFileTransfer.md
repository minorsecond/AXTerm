# Packet file transfer

Sending and receiving files over a connected AX.25 session from the
terminal's Transfers tab, on the Mac, iPad and iPhone. Winlink attachments
and the BBS file areas are covered in `Docs/Winlink.md` and
`Docs/PacketBBS.md`; this document is about station-to-station transfers.
The AXDP wire format is specified in `AXTERM-TRANSMISSION-SPEC.md` (§6, §9).

## Protocols

The protocol the operator picks in the Send File sheet is the protocol that
goes on the air. `SessionCoordinator.startTransfer` dispatches on
`TransferSendRoute.route(for:)`:

- AXDP: AXTerm's own protocol. FILE_META, then chunks with a CRC each, a
  completion request at the end and selective retransmission of whatever the
  receiver reports missing. Offered when the other station has shown it
  speaks AXDP.
- YAPP: the binary protocol LinFBB, BPQ, JNOS and most packet terminals
  speak. Offered whenever there is a connected session to the station, since
  it needs nothing from the other side but YAPP itself.
- 7plus and raw binary have no sender. They are never offered, and asking for
  one by name is refused with a reason rather than sent as something else.

Before this, every choice sent AXDP. A station picking YAPP to reach a BBS
put binary AXDP frames into the BBS's command prompt.

### YAPP on the wire

`YAPPProtocol.swift` follows the published frame table (WA7MBL, with the
YAPPC checksum extension). SI is ENQ 01, RR is ACK 01, a header is SOH, a
length, the name and size as NUL-terminated ASCII; data blocks are STX, a
length (0 meaning 256) and the data. There is no per-block acknowledgment:
the sender streams blocks and AX.25 carries them, and the handshakes happen
only at the start (SI/RR, HD/RF) and the end (EF/AF, ET/AT). A receiver that
answers RT instead of RF asks for YAPPC checksums, and AXTerm adds them when
sending. AXTerm answers RF as a receiver.

The implementation this replaced had invented its own frames (SI as SOH 01,
an ACK after every block), so it could only talk to itself.

`YAPPFrameParser` splits frames out of a byte stream. An I-frame can end in
the middle of a block or carry the end of one block and the start of the
next, so nothing assumes one frame per packet. When sending, blocks are
sized to paclen minus three so each one, with its header bytes and a
possible checksum, still fits a single I-frame for receivers that do.
The paclen is the one in use when the transfer starts. It can change
later in the session (transmission spec §7.8.1); a larger one leaves the
blocks as they are, and a smaller one splits a block across two
I-frames, which the parser above already handles.

YAPP bytes are foreign protocol bytes (spec §16). They go out as plain
PID 0xF0 I-frames, and `YAPPSessionTransfer` claims the session's delivered
byte stream for the length of the transfer, so the terminal and AXDP
reassembly never see them. The claim is released when the transfer ends,
after the other side's CA when it was canceled.

### Receiving YAPP from a BBS

After the operator asks a BBS to download a binary file, the BBS sends SI.
`SessionCoordinator.interceptUnclaimedDelivery` looks at each packet on a
terminal session before the terminal does, and starts a YAPP receive only
when:

- the packet is exactly the two bytes ENQ 01 (`YAPPProtocol.isSendInitPacket`),
  and
- nothing else is being transferred with that station.

A BBS sends SI as a packet of its own, and ENQ never appears in text, so
those two bytes inside a line of text, or followed by anything, stay text
and reach the terminal unchanged. AXTerm answers RR, the header names the
file, and the offer goes through the same rules and prompt as an AXDP offer.

## Offers

An offer is judged in the coordinator as it arrives
(`SessionCoordinator.applyOfferPolicy`, rules in `TransferOfferPolicy`):

1. A station on the deny list is declined.
2. A file over the size cap is declined, whoever sent it. The default cap is
   1 MB, set under Settings › Packet Node › File Transfers. A received file
   is held in memory until it is complete, and a megabyte is more than two
   hours of a 1200 baud channel.
3. A station on the allow list is accepted.
4. Anything else is put to the operator.

This used to run in the terminal view's `onChange`, so an offer that arrived
while the operator was on the map was neither judged nor prompted for, and
on the Mac the terminal is torn down on navigation. The coordinator exists
for the life of the app on every platform, and `IncomingTransferPromptHost`
shows the prompt from the main window whatever page is up. Waiting offers
are also listed at the top of the Transfers tab with Accept and Decline.

The prompt states the size and the protocol. When an earlier transfer with
the same station finished this session, it also estimates the airtime from
that transfer's measured rate. With no measurement it says nothing about
time, rather than quoting a guess.

## Where received files go

| Platform | Folder |
|---|---|
| Mac | `~/Downloads/AXTerm Transfers` (Documents if there is no Downloads) |
| iPhone and iPad | `Documents/AXTerm Transfers`, shown in the Files app under AXTerm |

`ReceivedFileStore` owns the choice. On iOS the app's Downloads folder is
private to the app and the Files app never shows it, which is where files
used to go. Documents appears in Files once the app declares file sharing
(`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` in the iOS
target's Info.plist).

Names from the other station are untrusted. `ReceivedFileStore.sanitize`
keeps only the last path component, so `../x` and `C:\DOS\X.ZIP` cannot
climb out of the folder; it replaces control characters, drops leading dots
so nothing arrives hidden, and caps the length. Nothing is ever overwritten:
a second `report.txt` is saved as `report 2.txt`, then `report 3.txt`.

A finished inbound transfer shows "Saved to AXTerm Transfers" with Quick
Look on every platform, Show in Finder and Open on the Mac, and Share on iOS.

## Text from a session

Some files arrive as plain lines in the terminal rather than by a transfer
protocol. Two kinds are kept as files, in the same folder and the same
Transfers list as any other received file, with protocol shown as "Text".
The lines still appear in the transcript as before. `ReceivedText.swift`
holds the logic; the terminal model (`ObservableTerminalTxViewModel`) feeds
it every byte it receives from a session, after AXDP envelopes and other
protocol bytes are taken out, and `SessionCoordinator.saveReceivedText`
saves and lists the result.

Each station has its own state, keyed by callsign like the terminal's own
line buffers, so two stations sending at once never mix. Line assembly here
keeps blank lines (the transcript drops them): a CR ends a line, an LF just
after a CR belongs to it even when the two arrive in different I-frames, and
a lone LF ends a line.

### A mailbox's text download

When a mailbox types out a text file it puts a BEGIN line before it and an
END line after it, carrying the name and the exact byte count
(`Docs/PacketBBS.md` §14, "A typed-out text file is marked", defines the
format and how the count is taken). On a BEGIN line from a station, AXTerm
collects that station's following lines until the END line for the same
name arrives at the point where the count has been reached. A marker-like
line before that point is part of the file.

It puts an LF after each line, drops the last one when the total is one
more than the count (the file had no final newline), and saves the result
under the name from the BEGIN line, sanitized and never overwriting
(`ReceivedFileStore`, so a second copy is `t3k_text 2.txt`). The row is
inbound and completed, with Quick Look, Show in Finder and Open, and the
console says where the file went.

When the file does not all arrive, AXTerm saves what did arrive under a
name that says so, `t3k_text (incomplete).txt`, and marks the row failed
with the reason, keeping the file's actions. On a 1200 baud link the part
that arrived cost real airtime, and most of a net script is still worth
reading; the name and the row keep it from passing for the whole file. It
counts as incomplete when:

| What happened | What is kept |
|---|---|
| more than the count arrives with no END line | the lines before the one that went past the count |
| the END line came before the count was reached, and the count was then passed | the lines before that END line, since lines were lost before it |
| the link closes or fails first | everything collected, the partial last line included; the lines before an early END line if one came |

A link that closes right after the BEGIN line, before any of the file,
saves nothing. A BEGIN line announcing more than 16 MB is not believed.

### Capture

The record button beside the message field turns Capture on for the session
on screen, on the Mac and on iOS. While it is on, every line that station
sends is kept: data only, so no frames, protocol bytes, AXDP envelopes,
system lines or the operator's own lines. A complete AXDP chat message from
the station counts as its lines. Turning it off saves the lines, each ending
in LF, as `K0EPI-8 2026-10-01 0603.txt` (the station as the terminal names
it, then the local date and time the capture began) with a Transfers row,
and the console says where it went. A capture is per session: it stops and
saves when that session's link closes or fails, and a capture with nothing
in it saves no file and says so. A line still incomplete when Capture is
turned off is not included; one cut off by the link closing is.

Capture and a marked download can run at once over the same lines; each
gets its own file.

### Not covered

Text arriving over one of AXTerm's own outbound NET/ROM circuits goes
straight from the coordinator to the console and does not pass the terminal
model, so neither a marked download nor Capture sees it. A caller reaching a
mailbox through a node by AX.25 (connect to the node, then `BBS`) is covered,
since that text arrives on an AX.25 session.

## Pause, resume, cancel

- Pause stops sending after the chunk or block already handed to the link.
  Only outbound transfers have a Pause button; a receiver cannot make the
  sender wait.
- Resume restarts the AXDP chunk loop that pause ended, or pumps YAPP blocks
  again. Resume used to set the status back to Sending without restarting
  anything, and the transfer sat there for good.
- The receiver is not told about a pause. AXDP has no pause message and
  YAPP has none either, so the receiving row goes by what it can see
  (`TransferPace` in BulkTransfer.swift). When nothing has arrived for four
  times the usual gap between chunks, and never less than 15 seconds, it
  says "Waiting for K0EPI-3" instead of "Receiving" and drops the rate and
  time remaining. It goes back to Receiving when data arrives. The sender's
  row drops them too while paused.
- The rate on both sides is the bytes over the time data was moving. It is
  measured up to the last chunk, not up to the present moment, and a long
  silence is left out, so it holds still through a pause instead of sinking
  toward zero while the time remaining climbs.
- Cancel tells the other station. AXDP has no abort message, so cancel sends
  the NACK a receiver sends to decline (session ID, message ID 1). An older
  AXTerm reads that as "declined" and stops; a newer one marks the transfer
  canceled. YAPP sends CN and waits briefly for CA. Either way both ends
  finish canceled and the per-transfer maps are emptied.

## When a transfer goes quiet or the link drops

A transfer riding a connected session fails the moment that session closes
or times out, with the reason: "The link to N0CALL was lost: it stopped
answering." or "The link to N0CALL closed before the transfer finished."

Everything else is watched by `TransferWatchdog`, which fails a transfer that
has shown no activity for too long:

| Waiting for | Limit |
|---|---|
| The other operator to accept | 10 minutes |
| This operator to answer an offer | 9 minutes (so an offer the sender gave up on is never accepted) |
| Chunks to leave (sending) | 5 minutes |
| The receiver to confirm the file arrived | 3 minutes |
| Anything to arrive (receiving) | 10 minutes, long enough for a sender's pause |

Paused transfers are not timed out on the sending side.

## Sending from each device

- The + button on the Transfers tab opens the file picker. Several files can
  be picked at once and are queued, one Send File sheet after another.
- On the Mac, File › Send File… (⌘⇧F) opens the terminal's Transfers tab
  and the picker, from any page.
- Files can be dropped on the terminal on the Mac and iPad. Drops are loaded
  as file representations, because a drag out of Files or Photos on iPad
  carries the file's own type and no file URL. Several dropped files queue.
- A file picked on iOS is copied into the app's temporary folder while its
  security scope is held, and the scope is released straight after
  (`OutgoingFileStaging`). A picker failure is reported in an alert.

The Send File and offer sheets keep their fixed sizes on the Mac and size
to the device on iPhone and iPad.

## Notifications

When the app is not frontmost, an offer posts a notification. A transfer
that finishes, fails, or is canceled by the other station posts one too,
following the "only when inactive" setting like the app's other alerts.
Transfers the operator ended themselves post nothing. The switch is
"Notify about file transfers" under Settings › Notifications.

## Tests

- `TwoStationTransferTests`: two complete stations joined by an in-memory
  KISS link. AXDP and YAPP byte-for-byte at several sizes, both directions,
  pause and resume, cancel from either end, radio silence and disconnects,
  declines, allow and deny lists with no terminal on screen, the size cap,
  name collisions, hostile names, and YAPP-looking bytes in ordinary text.
- `YAPPProtocolTests`: exact frame bytes, the stream parser, both handshakes,
  and a sender and receiver joined through a randomly chopped stream.
- `ReceivedFileStoreTests`, `TransferPoliciesTests`: the folder per platform,
  names, dispatch, offers, the watchdog, notifications, device wording.
- `TransferSheetHostingTests`: the sheets and list laid out off screen, with
  no publishing during view updates.
- `TextDownloadMarkersTests`: the marker lines, the count (CRLF, a lone CR,
  blank lines, a form feed, no final newline), line assembly across frames,
  byte-identical rebuilding, marker-like lines inside a file, missing lines,
  too many lines, a link closing mid-file, capture naming.
- `TextDownloadCaptureTests`: a real mailbox typing a file to a simulated
  caller whose frames go through the terminal model's own receive path. The
  saved file is byte-identical, the Transfers row is right, a second copy is
  saved beside the first, a hostile name is sanitized, a count mismatch and a
  dropped link save an incomplete file, two stations interleaving stay apart,
  and Capture keeps only the station's lines, stops when the link ends, and
  saves nothing when nothing came.
