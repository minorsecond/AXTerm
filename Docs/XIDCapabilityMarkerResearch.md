# XID capability marker: interop research

Date: 2026-10-11. Status: research only, nothing implemented.

## Question

AXTerm wants to learn whether a connected AX.25 peer also runs AXTerm. Today it asks with a 6-byte `AXDP?` UI probe, or with an AXDP PING inside the connection when there is a sign (AXTERM-TRANSMISSION-SPEC.md, 6.x.3). The idea studied here is to carry a private marker of about 4 bytes in the AX.25 2.2 XID frame that AXTerm already sends before its first SABM to an unknown station (spec 7.5.1).

Three encodings were considered:

- (a) an unassigned PI inside group 0x80;
- (b) a second information element after group 0x80, for example GI 0xF0 with its own group length;
- (c) the marker only in an XID response, sent when the peer's XID command carried it.

The encoding is only safe if every other stack ignores what it does not recognize instead of rejecting the XID (FRMR, DM, refusing the link) or misreading the known parameters. This document reports what the source code of each stack does.

## Sources read

| Stack | Source | Revision read |
|---|---|---|
| Dire Wolf | github.com/wb2osz/direwolf `src/xid.c`, `src/ax25_link.c` | master at `eda1383f5fa9` (2026-05-19) |
| Linux kernel AX.25 | torvalds/linux `net/ax25/ax25_in.c`, `ax25_std_in.c`, `ax25_ds_in.c`, `ax25_subr.c`, `include/net/ax25.h` | `4f10f1dfb235`, the parent of the commit that removed `net/ax25` (see below); identical to `69050f8d6d07` |
| LinBPQ / BPQ32 | github.com/g8bpq/linbpq `L2Code.c`, `cheaders.h` | master at `4b7a47b62b44` (2026-09-23) |
| JNOS2 | github.com/DigitalHERMES/jnos2 (unofficial mirror) `lapb.c`, `ax25.c`, `ax25subr.c`, `lapb.h`, `hlrevamp2022/ax25.c` | `55558642d3bb` (2022-06-21) |
| QtSoundModem | github.com/g8bpq/QtSoundModem `ax25_l2.c`, `ax25.c`, `UZ7HOStuff.h` | `9cd2735bc970` (2025-11-10) |
| AX.25 2.2 spec | "AX.25 Link Access Protocol for Amateur Packet Radio, Version 2.2 Revision: 10 September 2017", copy at wiki.oarc.uk (`packet:ax25.2.2.10.pdf`) | as published |

Line numbers below refer to those revisions. BPQ files use CRLF line endings; the numbers count lines the same way either way.

## The specification

Section 4.3.3.7 (page 31 of the 2017 revision) is the relevant text:

- "A parameter field containing an unrecognized PI is ignored."
- "The parameter fields described below represent the minimum implementation and do not preclude the negotiation of other parameters between consenting stations."
- "The information field consists of zero or more information elements." Each element starts with FI, GI and a two-octet GL. So a second element after group 0x80 is legal on paper.
- PI/PL/PV fields "are placed into the information field of the XID frame in ascending order."
- "A PL value of zero indicates that the associated PV is absent."
- "A FRMR error condition may be established if the received XID command information field exceeds the maximum defined storage capability of the station, if the receiving station is using AX.25 version 2.0 or earlier versions, or the receiving station wants to use the defaults for version 2.0 or earlier."

Section 6.3.2 says a pre-2.2 station answers an XID command with FRMR and the sender then uses 2.0 defaults. Appendix C5.3 says the station that initiates the connection sends XID after it receives the UA. AXTerm sends it before the SABM instead, which matters for Dire Wolf (below). The spec says nothing about a station that does not implement XID other than the FRMR answer, and nothing about unknown Group Identifiers.

The ISO 8885 text (and its successor ISO/IEC 13239) is not freely available and was not read. The claim that GI 0xF0 is "user defined" in ISO 8885 comes from the task description and could not be checked here.

## Dire Wolf

Dire Wolf parses XID fully in `xid_parse` (`xid.c` 148 to 372).

Structure checks. Byte 0 must be 0x82 and byte 1 must be 0x80, or the function returns 0 (lines 182 to 194). The group length is read from bytes 2 and 3, and the loop runs `while (p < info + 4 + group_len)` (line 200). Nothing after the first group is parsed.

Unknown PI. The `switch (pind)` ends in `default: break; // Ignore anything we don't recognize.` (line 361). Its value is read and dropped. There is one catch, at lines 205 to 210:

```c
plen = *p++;		// should have sanity checking
if (plen < 1 || plen > 4) {
  ...
  return (1);		// got this far.
```

A parameter with PL 0 or PL greater than 4 stops the parse at that point. The function still returns success, so whatever followed that parameter is lost and the caller fills those values with defaults (`negotiation_response`, `ax25_link.c` 6832 onward: N1 256, k 4, T1 3000, N2 10). A marker placed before PI 6, 8, 9 or 10 with PL 5 or more would therefore silently change what Dire Wolf negotiates. Placed last with PL 1 to 4, it is ignored with no message.

PIs 65, 66 and 67 are named in `xid.c` lines 70 to 73 (`PI_Compression_Algorithm_Mask`, `PI_TX_Window_Bits`, `PI_RX_Window_Bits`, with the comment "Is this stanard or Dave's creation?") but not handled. They should be avoided for the marker anyway.

Extra bytes after group 0x80. They are not parsed. Lines 365 to 368 print a red console line, `XID error: Frame / Group Length mismatch.`, and the function still returns 1. Negotiation is unaffected, but every XID carrying encoding (b) would put an error line on the Dire Wolf operator's screen.

Group length larger than the bytes present. There is no bound against `info_len`: the loop and the value loop (lines 200 to 213) read past the end of the information field into whatever follows in the frame buffer. Group length smaller than the bytes present gives the mismatch message above.

What it sends. `xid_frame` (`ax25_link.c` 5192 to 5276) answers an XID command with P=1 by building its own fresh XID response from the parsed values (`xid_encode`). It does not echo the received field, so a marker never comes back from Dire Wolf. If `xid_parse` returns 0 (wrong FI or GI), Dire Wolf sends nothing at all.

Whether the XID is seen at all. Received frames are mapped to a link with `get_link_handle(..., (ftype == frame_type_U_SABM) | (ftype == frame_type_U_SABME))` (line 2341); for any other frame with no existing link the handler returns (line 2344). The link is freed when a connection ends (`dl_connection_terminated`, line 1833). So an XID sent before the SABM, the way AXTerm does it, is dropped without an answer unless a link for that station pair already exists. Dire Wolf itself sends XID only after UA to a SABME it sent (`mdl_negotiate_request`, called at line 4911 in state 5), and it retries on TM201 up to N2 times (`tm201_expiry`, lines 5658 to 5708).

Can it stop the link or change parameters wrongly? Not with encoding (a) if the marker is the last parameter and its PL is 1 to 4. Encoding (b) is harmless to the link but prints an error. A PL of 0 or above 4 placed before known PIs would change negotiated values.

| Case | Dire Wolf behavior |
|---|---|
| Parses XID | Yes, fully |
| Unknown PI in group 0x80 | Ignored if PL 1 to 4; PL 0 or above 4 aborts the parse there (rest lost, defaults used) |
| Second group after 0x80 | Ignored, red "Frame / Group Length mismatch" line |
| GL larger than bytes present | Reads past the end of the field |
| Reply to XID command | Its own XID response, never an echo; nothing if FI/GI wrong |
| XID before SABM | Dropped, no link handle |

## Linux kernel AX.25

Status first: the AX.25, NET/ROM and ROSE code was removed from mainline Linux by commit `dd8d4bc28ad7` ("net: remove ax25 and amateur radio (hamradio) subsystem", April 2026) and moved to github.com/linux-netdev/mod-orphan. Kernels already shipped by distributions still carry it. The files below are from the parent of that commit.

The kernel does not parse XID. `AX25_XID` is defined (`include/net/ax25.h` line 86) but never used in `net/ax25`. `ax25_decode` (`ax25_subr.c` 97 to 140) returns the control byte less the P/F bit, 0xAF, for a U frame.

With no connection (state 0), `ax25_rcv` (`ax25_in.c` 319 to 330) answers anything that is not SABM, SABME or DM, if it is addressed to one of our calls:

```c
if ((*skb->data & ~AX25_PF) != AX25_DM && mine)
	ax25_return_dm(dev, &src, &dest, &dp);
```

So an XID command before the SABM gets a DM. On a link that exists (states 1 to 4), 0xAF matches no case in the state machines and falls to `default: break;` (`ax25_std_in.c` 91, 129, 254, 409; `ax25_ds_in.c` 86, 133, 269). It is ignored. Only `AX25_FRMR` and `AX25_ILLEGAL` cause a link reset (`ax25_std_in.c` 248 to 252, 403 to 407), and XID is neither.

The information field is never looked at, so the encoding of the marker cannot matter. The DM is what AXTerm already treats like FRMR (spec 7.5.1).

| Case | Linux kernel behavior |
|---|---|
| Parses XID | No |
| Unknown PI, second group, GL mismatch | Not applicable, field never read |
| Reply to XID command | DM with no link; ignored on an existing link |
| Can it stop the link | No |

## LinBPQ / BPQ32

BPQ parses XID and, unlike the others, builds its response by editing the received frame in place and sending it back.

Entry. With no link, `L2FORUS` (`L2Code.c` 650 onward) sends FRMR to an XID if 2.2 support is off (`SUPPORT2point2`, lines 720 to 729; it defaults to 1 at line 169), applies the exclude list, permitted-calls list and port user limit (DM at 813), the KISSHF attach check (DM at 826), and ignores the call entirely when the node has neither NODE nor BBS (line 754). It then calls `ProcessXIDCommand` for a command; an XID response with no session is logged and dropped (lines 833 to 843).

Parsing (`ProcessXIDCommand`, lines 853 to 1041). The KISS interlock check can answer DM (lines 873 to 877). The first two bytes must be 0x82 0x80 (line 879), or the code jumps to `BadXID`, which sends FRMR (lines 1038 to 1039). The loop is `while (xidlen > 0)` over the first group only (line 889), reading PI, PL and PL value bytes with no check against the frame length. The switch handles 2, 3, 6, 8 and 16 and has no default, so an unknown PI is read and ignored. PL may be any value.

Response. After the loop BPQ sets the control byte, swaps the addresses and queues the same buffer (`L2SWAPADDRESSES(Buffer)`, `PUT_ON_PORT_Q(PORT, Buffer)`, lines 1024 to 1035). The buffer length is not changed. The only edits are PI 3, rewritten to BPQ's own choice (lines 922 to 928), and PI 16, renamed 17 or cut (lines 940 to 956). Every other byte of the received information field goes back to the sender, which includes:

- an unknown PI in group 0x80 (encoding a), unchanged;
- a second group after group 0x80 (encoding b), unchanged;
- PI 6 and PI 8 exactly as offered (lines 932 to 938 do nothing with them).

This is the most important finding for encoding (c). An XID response from BPQ carries back whatever marker AXTerm put in its command. If the "answer" form of the marker were the same bytes as the "question", a BPQ node would look like AXTerm.

PIs to avoid. PI 16 is BPQ's L2 compression request and PI 17 its acceptance (`L2SENDXID`, lines 3926 to 3990, and lines 940 to 956, 1186 to 1191). The PI 16 path when compression is off does `ptr[3] -= 2; Buffer->LENGTH -= 2;` and resets the parse pointer to the start of the field, which truncates the last two bytes of the frame and re-parses from the FI. A marker must not use 16 or 17, and must not follow a PI 16.

PI 3 bit order. BPQ's constants (`cheaders.h` 207 to 211) are `OPMustHave 0x02A080`, `OPSREJ 4`, `OPSREJMult 0x200000`, `OPREJ 2`, `OPMod8 0x400`, read most significant byte first. Its own XID sends PI 3 as `22 A4 86` and PI 2 as `00 21` (lines 3958 to 3979). Dire Wolf and AXTerm send PI 2 as `21 00` and PI 3 as `86 A4 02` (AXTerm with SREJ offered, `AXTerm/AX25/AX25XID.swift`). The first and third bytes are swapped between the two conventions. `ProcessXIDCommand` rejects a PI 3 that lacks all of `OPMustHave`, `OPMod8` and `OPSREJMult` (lines 909 to 918). Worked through by hand, AXTerm's `86 A4 02` gives `0x86A402 & 0x02A080 = 0x02A000`, which fails the first test, so BPQ at this revision should answer AXTerm's XID with FRMR before it reaches any marker. This is an inference from the constants, not an observation. AXTERM-TRANSMISSION-SPEC.md 7.5.1 records BPQ answering DM; the DM paths in this code are the interlock (875), the port user limit (813) and KISSHF (826), so the node behind that DM may differ in configuration or version. The XID command is answered either way, so the link still comes up.

XID on an established link. A command when the link is in neither state 1 nor 2 calls `InformPartner(LINK, NORMALCLOSE)`, which closes the attached circuit, and the XID is dropped (lines 1137 to 1145). AXTerm must never send XID inside an established session to a BPQ node.

When BPQ initiates (it sends XID before its SABM, `L2SENDXID`) and AXTerm answers, BPQ's response handling (lines 1148 to 1202) looks only for PI 17 and ignores everything else, so a marker in AXTerm's response would not hurt it. Encoding (c) never puts one there anyway, because BPQ's command does not carry the question.

| Case | LinBPQ behavior |
|---|---|
| Parses XID | Yes, first group only |
| Unknown PI in group 0x80 | Ignored, echoed back unchanged in the response |
| Second group after 0x80 | Ignored, echoed back unchanged |
| GL larger than bytes present | Reads past the frame |
| Reply to XID command | The received frame edited in place (PI 3 and PI 16 only); FRMR on wrong FI/GI or missing PI 3 bits; DM on interlock, user limit, KISSHF |
| Can it stop the link | Not before SABM; an XID inside an established link closes the circuit |

## JNOS2

No XID support. A case-insensitive search of `lapb.c`, `lapb.h`, `ax25.c`, `ax25.h`, `ax25subr.c`, `ax25hdr.c`, `ax25dump.c` and `hlrevamp2022/ax25.c` finds no "XID". `lapb.h` (lines 31 to 38) defines no XID constant. `ftype` (`ax25subr.c` 261 to 269) returns the control byte less P/F for a U frame.

For a frame addressed to one of its calls with no link, `ax25.c` creates a control block (`cr_ax25`, line 831) and passes the frame to `lapb_input` (line 844). In `LAPB_DISCONNECTED` the switch ends `default: /* All others get DM */ if(poll) sendctl(axp,LAPB_RESPONSE,DM|pf);` (`lapb.c` 140 to 143). An XID command with P=1 before the SABM therefore gets a DM. In the other states unknown frames get a DM only on a command poll in the setup and disconnect-pending states (lines 188 to 195 and 213 to 216, inside `LAPB_SETUP` at 158 and `LAPB_DISCPENDING` at 198) and are ignored when connected (line 385). The information field is never read.

The mirror read is from 2022. The official JNOS 2.0 releases from VE4KLM may be newer and were not checked; whether a later release added XID is unknown.

| Case | JNOS2 behavior |
|---|---|
| Parses XID | No |
| Unknown PI, second group, GL mismatch | Not applicable |
| Reply to XID command | DM if P=1 with no link; ignored when connected |
| Can it stop the link | No |

## UZ7HO SoundModem / QtSoundModem

QtSoundModem only decodes XID for the monitor display (`ax25.c` 2800 to 2848). That decoder checks 0x82 0x80, walks the first group, prints PIs 2, 3, 6 and 8 and skips anything else. It has no effect on the link.

Its own layer 2 (`ax25_l2.c`, used by AGW clients; in KISS mode the host stack does layer 2) has no XID case. With no session, `analiz_frame` answers a command that is not SABM like this (lines 1559 to 1585, the inner switch at 1565):

```c
case U_UI:
	break;
default:
	set_FRMR(snd_ch, path, f_id);
```

So an XID command before the SABM, to a call registered by an AGW client, gets FRMR with "invalid control" (`set_FRMR`, line 718). On an active session the frame switch (lines 1632 to 1689) has no XID case and ignores it. The information field is never read.

The Windows UZ7HO SoundModem is closed source. That it behaves like QtSoundModem is an inference: QtSoundModem is G8BPQ's port of it.

| Case | QtSoundModem behavior |
|---|---|
| Parses XID | Monitor display only |
| Unknown PI, second group, GL mismatch | Not applicable to the link; monitor skips unknown PIs |
| Reply to XID command | FRMR with no session (AGW mode); ignored in a session; KISS mode defers to the host |
| Can it stop the link | No |

## Others

- FBB: a BBS that runs over the host's AX.25 layer (kernel sockets, BPQ, or TNC host mode) rather than its own layer 2, as far as is known. Source not read.
- Xrouter (G8PZT), TheNet, XNet, Kantronics and AEA firmware: closed source, not read. No documentation found on their XID handling. A pre-2.2 implementation answers an unknown control byte with FRMR or DM or ignores it (the 2.2 spec's own expectation, 6.3.2) and would never look at the information field. That is an inference.
- Mobilinkd TNC: KISS only, no layer 2, not relevant.

## Summary by stack

| Stack | Parses XID | Unknown PI in 0x80 | Extra group after 0x80 | Reply | Link at risk |
|---|---|---|---|---|---|
| Dire Wolf | Yes | Ignored (PL 1 to 4) | Ignored, error printed | Own XID; drops pre-SABM XID | No (marker last, PL 1 to 4) |
| Linux kernel | No | n/a | n/a | DM | No |
| LinBPQ | Yes | Ignored, echoed | Ignored, echoed | Echo of the received field, or FRMR/DM | No before SABM |
| JNOS2 | No | n/a | n/a | DM | No |
| QtSoundModem | Monitor only | n/a | n/a | FRMR (AGW mode) | No |
| AXTerm (today) | Yes | Skipped | Ignored | Own XID | No (GL beyond the data returns nil) |

## Recommendation

Use encoding (a), with the marker always as the last parameter of group 0x80:

- PI: a single value above 10 (keeps the spec's ascending order), outside 16, 17 and 65 to 67. A high value is less likely to collide with a future assignment. It should be checked against the ISO/IEC 13239 parameter table before it is frozen, which this research could not do.
- PL: exactly 4 (Dire Wolf aborts on PL 0 or above 4).
- PV: two identifying bytes (for example `A` `X`), a version byte, and a role byte that differs between question and answer.
- GL must count the marker exactly. Both Dire Wolf and BPQ read past the field if GL is too large.

Do not use encoding (b). Every parser read handles only the first group, so it gains nothing, and Dire Wolf prints an error for every such frame.

Send the question form in the XID command to an unknown peer. All five stacks read either ignore it or never look at it, and none of them refuses the link because of it.

Put the answer form only in an XID response, and only when the received command carried the question. That is encoding (c) as the second half of (a). Responses to Dire Wolf, BPQ and everyone else stay byte-for-byte what AXTerm sends today. Count a peer as AXTerm only on the answer form. BPQ echoes the command's information field, so a response that carries the question form is an echo and proves nothing. A command that carries the question can only come from AXTerm, since no stack read here originates it, so the responding side learns the caller runs AXTerm from the command itself.

Limits to keep in view:

- The marker only travels where AXTerm sends XID: first contact with a station or after the XID cache lapses. It is a cheap extra sign for `AXTermSign` / `AXDPPeerMemory`, not a replacement for the UI probe or in-session PING.
- A node that terminates layer 2 (a BPQ node, a NET/ROM node) hides the far station. The marker only identifies the station at the other end of the AX.25 link itself.
- Never send XID on an established link (BPQ closes the circuit; Dire Wolf and the kernel ignore it).

Two findings outside the marker question, worth their own follow-up:

1. Dire Wolf drops an XID that arrives before the SABM, so on first contact with a Dire Wolf station AXTerm always waits out one RTO before its SABM.
2. BPQ reads PI 2 and PI 3 with the first and third bytes swapped relative to Dire Wolf and AXTerm and requires multi-SREJ, so by the constants it should FRMR AXTerm's XID. Worth confirming against a live BPQ before relying on BPQ ever answering with XID.

## Interop tests that would confirm this

None of these needs a radio. Use an audio loopback device (BlackHole on macOS, snd-aloop on Linux) or a pty pair, with PTT unconfigured, and never the station radios.

1. AXTerm unit tests, written first: the encoder puts the marker last with PL 4 and GL counting it; `AX25XIDParameters.parse` returns the same known values with and without the marker; a response identical to the command (the BPQ echo) is not taken as AXTerm; a response with the answer form is; a response without a marker leaves the peer unknown; AXTerm's response carries the answer only when the command had the question.
2. Dire Wolf parser offline: `xid.c` has a self-test (`gcc -DXIDTEST`, lines 604 to 700). Add vectors for AXTerm's command with the marker last and assert the parsed values are unchanged and nothing is printed. Add a PL 5 marker before PI 6 to show the abort, and a trailing GI 0xF0 group to show the mismatch message.
3. Dire Wolf live on loopback: AXTerm's KISS link to one Dire Wolf modem instance, a second instance on the same loopback running connected mode with a registered call. Expect no answer to the pre-SABM XID, then a normal SABM and UA. Then let Dire Wolf connect to AXTerm with SABME and check that AXTerm's XID response has no marker.
4. LinBPQ on the same loopback (a KISS port on a Dire Wolf modem): expect FRMR to AXTerm's XID and a normal connect. If BPQ answers with XID, check that the response is the echo and that AXTerm does not mark the node as AXTerm.
5. Linux kernel stack (an older kernel or the mod-orphan modules) with `kissattach` on a pty to a loopback modem: expect DM, then a normal connect.
6. QtSoundModem in AGW mode on loopback with a registered call: expect FRMR, then a normal connect.
7. Two AXTerm instances (Station B as the signed test copy) on loopback: both learn the other runs AXTerm from the XID exchange alone, with no `AXDP?` probe sent.
