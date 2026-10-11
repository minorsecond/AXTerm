# Retest of the home retest fixes, 2026-10-10

A (705) on `b100c209`, 145.650 PKTFM through Warbler, mailbox K0EPI-4. The
iPad on the same build from 15:52, with the TNC4 and the ID-50 as K0EPI-3.
The script is the one given in the session after the fixes for
`2026-10-10-home-retest.md` findings 1 to 14.

## Results

| Step | Result | Notes |
|---|---|---|
| 1a, 1b TNC4 connect | Pass | Reported as passing by the operator |
| 2 capability check | Pass | probe, PING, PONG at 15:47 (A answers with the PING). Run while the iPad was still on the old build, which is fine: this change is A's |
| 3b decline with uploads off | Pass (A) | "was declined: this station does not accept uploads." The iPad was on the old build, so its Send with YAPP Instead and Send Again could not show; retest on the new build |
| 4b AXDP upload to K0EPI-4 | Pass | Accepted, "Received Photo-20261010-155259.jpg (9K)." |
| 4d Move to Area › PARK | Pass, finding 2 | Moved, and the window said so; the sender and time were lost |
| 5 Send with YAPP Instead | Slow, finding 4 | Sent the same 9K; about 70 s lost to one frame resent ten times |
| 8 26.8 KB message, A to the iPad | Pass, findings 8 to 13 | Arrived whole; A read "Waiting to send…" until every frame had gone, then "Sending… 207 of 210 acknowledged"; the iPad's auto-scroll jumped on every delivery; K 1 and 128-byte frames throughout |
| 9 Messages with no radio on APRS | Pass, finding 14 | Banner and disabled actions as intended |
| 3b on the iPad's new build, 6, 7 | Pass | Reported as passing by the operator: Send with YAPP Instead and Send Again on a declined row, trusted upload into PARK, text download as a transfer |

## Findings

1. **The live call panel shows no progress for an AXDP upload.** A YAPP
   transfer gets a progress row in the panel on the BBS page; an AXDP upload
   shows only "receiving … by AXDP" in the transcript, with the progress in
   the toolbar chip. Proposed: the same row for AXDP (file, caller, bytes,
   percent, protocol, elapsed), and the arriving file at the top of Received
   with a progress bar until it is saved.
2. **Moving an upload into an area drops who sent it and when.** Move to
   Area forgets the upload's record, and a trusted upload straight into an
   area never records one. Proposed: keep the record per area and file,
   show a From column in the area's table (empty for the operator's own
   files) with "Uploaded by K0EPI-3, Oct 10 at 3:55 PM, moved from docs" on
   hover. Not shown to callers in `W`.
3. **Rows in a shared area's file list cannot be selected.** The table has no
   selection, so only the description text responds to a click, while the
   uploads list beside it selects normally. Proposed: selectable rows
   (several at once), and a menu with Open, Quick Look, Show in Finder, Edit
   Description… and Move to Trash… (confirmed, saying callers will no longer
   see it); double-click still edits the description. The same menu on iOS.
4. **The iPad resent one I-frame ten times although A acknowledged each
   copy.** Step 5, Send with YAPP Instead (the 9K photo, not the original).
   A's packet log: 21:59:45Z to 22:00:55Z the iPad sent I N(S)=3, 255 bytes,
   P=0, ten times about 8 to 9 s apart; A answered each with RR N(R)=4 about
   a second later. At 22:00:56Z the iPad sent N(S)=4 and the transfer went on
   at the normal pace (one out-of-order frame at 22:01:07Z, recovered by a
   single SREJ). About 70 s were lost, and the time estimate read 18 minutes
   during it. Unknown yet whether the ID-50 missed the RRs or the iPad's
   session did not act on them; the retransmissions also carried no poll,
   which AX.25 2.2 timer recovery expects. Needs the iPad's log. Any change
   is AX.25 behavior and waits for the operator's approval.
5. **The Send File sheet's Mailbox Area should be a picker, not a text
   field.** Operator request: free text is too error prone. Proposed: for an
   AXTerm station that has confirmed AXDP, the sheet asks the mailbox (a new
   AXDP message type) which areas take this caller's uploads, and offers
   Inbox plus those; with no answer the section is hidden. Needs a spec
   extension; the operator approved this design (16:20 local), to be built after the run. As shipped,
   the text field shows for every destination, so typing an area sends
   `U PARK` to BPQ, FBB or JNOS, where `U` may mean something else. The
   operator expects about 0.1% of stations to run AXTerm, so the section
   must show only for a station confirmed as an AXTerm mailbox. AXTerm is
   unreleased, so the new message type needs no compatibility handling.
6. **The AXDP probe costs airtime on almost every link for nothing.** Each
   connected station gets the text probe and up to two retries (3 UI
   frames, 10 to 30 s apart, `AXDPCapabilityProbe.maxAttempts`), and a "no
   AXDP" verdict is kept 24 h in memory only, so a relaunch probes everyone
   again. With about 0.1% of stations running AXTerm, nearly all of that is
   wasted. Proposed: one probe, no retries, only to a station that
   identifies as AXTerm (its greeting, or an AXDP message already heard
   from it) or when the operator picks AXDP in Send File; keep the verdict
   across launches. AX.25 behavior; the operator approved it (16:20 local), to be built after the run.
7. **The iPad's session history jumps up and back down when TX shows.**
   Seen on the iPad's Session view. The status strip keeps a slot for "TX"
   (park rehearsal 2026-10-08), so the word alone does not resize it. Likely
   causes, not yet confirmed: the strip growing for a receive warning (more
   padding and up to two lines) that is recomputed each time the TX light
   changes, with a timestamp up to 30 s old; or the transcript's trailing
   "Sending…"/"Delivered" row re-pinning the list. Waiting on what the strip
   and the last row show when it jumps.
8. **A sending a 26.8 KB message read "Waiting to send…" while the iPad had
   9.7 KB of it.** Step 8. `InlineSendStatus.make` shows waiting until every
   byte is on the air. The sent count also grows with every I-frame A
   transmits (retransmissions and other sessions included), and the
   acknowledged count is worked out from paclen, which the session changes
   mid-message. Proposed: waiting only before the first frame; sent and
   acknowledged bytes counted by the session from the frames themselves.
9. **The sender should see how far a long message has got.** Operator
   request. Proposed: a progress bar with "Delivered 9.7 of 26.8 KB" for any
   long send; the acknowledged part of the text darkened only for a
   plain-text send, where the other station really does see each line as it
   lands. For AXDP the text stays evenly dimmed until the whole message is
   acknowledged, and the bar says the other station sees it when it has all
   arrived (their own progress row is finding 4 of the home retest).
10. **The iPad's auto-scroll goes haywire while a long message arrives.**
    Each change to the trailing status row scrolls to the sentinel below the
    padding, which overshoots, and the repin then moves back: once per
    delivery. Finding 7 is very likely the same path, through the "Sending…"
    row's acknowledged count. Proposed: scroll only when the row appears or
    changes height, and to the row itself.
11. **AXDP chat goes uncompressed.** The 26.8 KB constitution went as one
    AXDP chat message of 26,816 bytes, plain text in the frames. Deflate
    makes this text 9.4 KB (LZMA 8.9 KB), about a third of the airtime: some
    5 minutes in place of 14 at the 32 B/s this link ran. Operator: compress
    AXDP payloads wherever it helps (approved; spec change, no compatibility
    needed since AXTerm is unreleased).
12. **Offer zip for a station without AXTerm.** Ordinary AX.25 has no
    compression other software decodes in a terminal session (LZHUF exists
    only in FBB and Winlink forwarding). Proposed: a Send File option that
    sends a file as a .zip by YAPP when the destination is not a confirmed
    AXTerm station; zip because every desktop and phone opens it without
    extra software (operator's choice).
13. **The session stayed at K 1 and 128-byte frames for the whole message.**
    XID at 22:11:20Z agreed N1 256 and k 4 both ways; A's learned route for
    K0EPI-3 reached K 4 and paclen 256 (the toolbar's K4 · P256); the
    session header read K: 1 throughout, every I-frame 128 bytes, 142 sent
    first time and 3 resent in 573 s (about 32 B/s). Every I-frame carried
    P=1, as the frame that fills a window of 1 does. Two causes: the message
    was cut into 128-byte frames when it was sent (a new paclen applies only
    to data segmented later), so a long message should be cut as it goes out;
    and the raise in K, which waits until nothing is outstanding, never
    applied, either because a K 1 stream never reaches that point as checked
    or because the target never reached this session. A test reproducing a
    long send with a raised target decides which. A's debug lines are not
    kept in the unified log, so this run left no trace of the decision.
14. **Switching a radio's channel should say the frequency does not
    change.** Operator request on step 9. Switch to APRS (Messages) and
    Switch to Packet (Terminal) change what AXTerm does on the radio, not
    the radio's frequency. Proposed: a confirmation first, for example
    "Switch IC-705 to APRS? AXTerm will send APRS on it and stop answering
    packet calls there. It does not retune the radio: set it to your APRS
    frequency (144.390 in North America) yourself." The packet direction
    names no frequency, since there is no single packet channel.

## Fixes

Each fixed test first, with the full macOS suite and the iOS build passing
before the commit. Not yet installed on A (705) or the iPad.

| Finding | Commit | What changed |
|---|---|---|
| 1 | `cae18ed3` | AXDP uploads get the live call panel's progress row; any upload waits at the top of Received with a progress bar |
| 2 | `694bc754` | Who uploaded a file stays with it in an area (migration v41); From column, not shown to callers |
| 3 | `3d86bc63` | Shared file rows select, with Open, Quick Look, Show in Finder, Edit Description and Move to Trash |
| 4 | `d01d1f75` | An ack held for the peer's burst waits 0.8 s of quiet after the carrier drops, and keeps waiting if it comes back. Cause found in the iPad's own log: A's RR keyed over the iPad's second frame |
| 5 | `6cf26b96` | Send File asks an AXTerm mailbox which areas take your uploads and offers those as a picker (new AXDP request and reply) |
| 6 | `b5bfd1dd` | The AXDP probe goes once, only to a station that says AXTerm or is remembered as one; verdicts kept across launches |
| 7, 10 | `b28606fb` | The iPad's history follows the status row only when the row changes kind, and scrolls to the row itself |
| 8, 9 | `b9ef1eb1` | "Waiting to send…" only before the first frame; counts from the session; a progress bar, and the message's line darkens as it is acknowledged (plain text) |
| 11 | `793533af` | AXDP chat compressed (deflate, else LZ4) when the peer can read it; per-message limit 256 KB |
| 12 | `3524883e` | Send File offers a .zip for YAPP to a station without AXTerm |
| 13 | `d12fc341` | A session grows once its peer confirms AXTerm mid-session; queued data is cut as it goes out, at the paclen in force |
| 14 | `896b5bb9` | Switching a radio between APRS and Packet asks first and says it is not retuned |

`ModemRadioLinkTests.testSetRadioOnConnectPushesThePacketSetup` failed once in
a full run during this work and passed three times on its own: a timing test
under load, unrelated to these changes.
