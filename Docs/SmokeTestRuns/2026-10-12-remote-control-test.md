# Remote control, node callsign and iPad fixes, test run 2026-10-12

A (705) on 145.650 with the node on K0EPI-7, mailbox on K0EPI-4. The iPad
(K0EPI-3) on the ID-50 and TNC4. A runs `eccafadc` or later; the iPad runs
`7d8e3008` or later. Sections 1 to 6 are on 145.650. Section 7 needs both
radios on 145.050 and goes last.

Write the result in the last column: Pass, Fail, or what happened.

## 1. The node on its own callsign

| # | Do | Expect | Result |
|---|---|---|---|
| 1.1 | iPad: connect to K0EPI-7, press Return | `AXTerm Node EPINOD:K0EPI-7`, the menu line, prompt `EPINOD:K0EPI-7}` | |
| 1.2 | Send `i`, then `inf`, then `info` | Each answered with the node line and the station info | |
| 1.3 | Send `nod`, `rou`, `j` | NODES, ROUTES and heard lists | |
| 1.4 | Send `m` | `? M — …` (MHEARD or MAIL, not guessed) | |
| 1.5 | Send `bb`, then `b` in the mailbox | Mailbox greeting, then "Back at the node." and the node prompt | |
| 1.6 | Send `by` | `73 de EPINOD`, link closes | |
| 1.7 | Connect to EPINOD | Same greeting and prompt as 1.1 | |
| 1.8 | Connect to K0EPI-2 | Not the node prompt | |
| 1.9 | With the node link up, also connect to K0EPI-4; then disconnect one | Both stay up together; the other keeps working | |
| 1.10 | iPad on the K0EPI-4 call | The header never says "Answered by K0EPI-7" | |
| 1.11 | A: Packets, wait for a NODES broadcast | Source is K0EPI-7 | |
| 1.12 | A: Settings › Packet Node › Node callsign list | No K0EPI-2 and no K0EPI-4 in it | |

## 1b. Talking with the operator

Someone at A for these.

| # | Do | Expect | Result |
|---|---|---|---|
| 1b.1 | iPad at the node (K0EPI-7): `T` | "Paging the operator…"; on A a banner "K0EPI-3 wants to talk (at the node)" with Answer and Not Now, and a notification with the same | |
| 1b.2 | A: Not Now | iPad: "The operator isn't at the station. BBS leaves them mail." and the node prompt | |
| 1b.3 | iPad: `T` again, wait a minute without answering | The same message after about a minute; the banner goes | |
| 1b.4 | iPad: `T`, A: Answer | iPad: "You are talking with the operator. /EX takes you back."; A's terminal shows K0EPI-3 connected; the banner says "Talking with K0EPI-3" | |
| 1b.5 | Type back and forth | Each side sees the other's lines; A's replies come from K0EPI-7 (A's Packets) | |
| 1b.6 | iPad: `/ex` | "Back at the node." and the prompt; `i` works | |
| 1b.7 | `T`, Answer, then A: End Chat | iPad: "The operator left the chat." then "Back at the node." | |
| 1b.8 | At the mailbox (K0EPI-4): `T`, Answer, chat, `/ex` | Same, ending "Back at the mailbox." and the `>` prompt | |
| 1b.9 | With both the node and mailbox links up, chat from the node | A's replies go on the node link only, never the mailbox's | |
| 1b.10 | Answer from the Mac notification's button (A's window in the back) | The chat starts the same way | |

## 2. Owner codes (code sign-in)

| # | Do | Expect | Result |
|---|---|---|---|
| 2.1 | Note a code just before it changes, wait about 90 s, send `OWNER <code>` | Signed in as the owner | |
| 2.2 | Send a code at least 3 minutes old | "That code is not right." | |
| 2.3 | Reconnect and send the code from 2.1 again | Refused as already used | |
| 2.4 | Signed in by code, send `PWR 705 5` | Refused: it needs a paired device's key | |

## 3. Radio control (key sign-in)

Do this where you can see the 705. Read the FT-710 only: it carries the
VarAC/VARA link, so do not change it while that runs.

| # | Do | Expect | Result |
|---|---|---|---|
| 3.1 | At K0EPI-4: Sign In as Owner | Signed in, then the `Owner commands:` line | |
| 3.2 | `PWR 705` | The power in watts, a clean number | |
| 3.3 | `PWR 705 5` | The 705 shows 5 W | |
| 3.4 | `PWR 705 75` | Refused, out of the 705's range | |
| 3.5 | `PWR 710` | The FT-710's power in watts (read only) | |
| 3.6 | After 3.3, send nothing for 2.5 minutes | "Nothing heard from you: put back PWR", and the 705 goes back to its old power | |
| 3.7 | At the node (K0EPI-7): Sign In as Owner, `PWR 705` | Works the same from the node | |
| 3.8 | Send a 40-character junk word | The echo shows 16 characters and "…" | |

## 4. Code lockout (last of the 145.650 tests: codes lock for 15 minutes)

| # | Do | Expect | Result |
|---|---|---|---|
| 4.1 | Send three wrong codes, then the right one | "Too many wrong codes. Codes are refused for now; a paired device's key still works." | |
| 4.2 | Sign In as Owner | The key still signs in | |
| 4.3 | A: Settings › Remote Control | A Code lockout section with the end time; Recent activity lists the wrong codes | |
| 4.4 | Optional: tell Claude, who restarts A | The lockout is still shown after the restart | |
| 4.5 | Click Clear Lockout, then send a fresh code from the iPad | Signed in | |

## 5. Settings and the iPad

| # | Do | Expect | Result |
|---|---|---|---|
| 5.1 | A: Settings › Packet Node | "On the air now" matches what runs; NET/ROM Node, Mailbox and Ping each have a "Carried on" row; the 705 shows its digipeater and ID beacon; the switched-off radio is one line with Show Their Settings | |
| 5.2 | A: File Transfers in the sidebar | Its own page, with the auto-accept and auto-deny lists and the largest file | |
| 5.3 | iPad: the same two pages | As on A | |
| 5.4 | iPad terminal: the Show menu | Every frame type listed, RR and the other link frames among them; choosing them shows them | |
| 5.5 | Leave an iPad session sitting idle | The console keeps its lines in view. If it goes blank, note the time and leave the app running so Claude can copy its log | |

## 6. Nothing else changed

| # | Do | Expect | Result |
|---|---|---|---|
| 6.1 | iPad: YAPP send of a small file to K0EPI-4 | Arrives whole | |
| 6.2 | A: APRS messages and beacons (only if you switch to APRS) | As before | |

## 7. On 145.050, through the LinBPQ node

Both radios on 145.050. Claude follows the LinBPQ log for each step. NODE is
the LinBPQ node's callsign.

| # | Do | Expect | Result |
|---|---|---|---|
| 7.1 | iPad: plain session to NODE, a few commands | Answers as usual, no binary in its log | |
| 7.2 | iPad: connect to NODE, `C K0EPI-2` | The node connects; its log shows the downlink to K0EPI-2 | |
| 7.3 | iPad: Send File | Lists "K0EPI-2 via NODE", badge reads AXDP within a few seconds | |
| 7.4 | Send a small photo by AXDP | A is offered it from K0EPI-3, not NODE; it arrives whole | |
| 7.5 | Type a line | A shows it as plain text | |
| 7.6 | A: Packets | No PING to NODE; NODE is not remembered as AXTerm | |
| 7.7 | `B` to the far end | Back at the node; Send File no longer lists K0EPI-2 | |
| 7.8 | A: Packet Node, Announce on with alias AXTNOD; wait for NODES | The LinBPQ log shows it learned AXTNOD | |
| 7.9 | iPad: connect bar in NET/ROM mode to K0EPI-2 | A circuit opens, A's node prompt appears | |
| 7.10 | Badge and Send File | AXDP; "K0EPI-2 over NET/ROM"; a small photo arrives whole in NET/ROM frames | |
| 7.11 | A: Run the node and Announce back as they were | Back as before | |

## Findings

