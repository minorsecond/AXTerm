# Park test rehearsal, 2026-10-08

Plan: [ParkRehearsalPlan.md](../ParkRehearsalPlan.md). A (705) on `44ada7ba`
(pid 46344), 145.650 PKTFM through Warbler; the iPhone on `44ada7ba` with the
TNC4 and the ID-50 as K0EPI-3. Mailbox K0EPI-4, Winlink peer-to-peer K0EPI-2.

## Results

| # | Result | Notes |
|---|---|---|
| P1 | pass | Connected through Warbler at 11:33:25Z; 145.650 PKTFM read back |
| P2 | pass | Mailbox on the air as K0EPI-4 |
| P3 | pass | Winlink peer-to-peer answering on |
| P4 | pass | PARK area, `~/Documents/AXTerm-BBS-Park`. Return did not press Share (finding 2) |
| P6 | pass | pid 46344 |
| R1 | pass | Add Photos opened the size sheet; `Photo-20261008-052732.jpg` 12 KB, 196 × 262, no location |
| R1b | pass | `IMG_2820.HEIC` (4.9 MB, has a location) went in at Medium: `IMG_2820.jpg` 24 KB, 251 × 335, no location. Pixel sizes look small (finding 5) |
| R1c | pass | On air: <1m, 5m, 3m at 90 B/s |
| R2 | pass, with findings | `W PARK` answered all three first-call questions before it listed (finding 8). TIME matched A's On air. Names cut to 17 characters (finding 11) |
| R3 | **fail** | `D IMG_2820.jpg` from 11:42:40Z at about 46 B/s (two 127-byte frames per round trip, K 2). A stopped it at 11:47:36Z, "No answer from the other station for 120 seconds", and sent DISC, though the phone acknowledged every frame up to 11:47:34Z (finding 17). The phone shows it failed: "The link to K0EPI-4 closed before the transfer finished" |
| R4 | pass | Photo Library picked; sent at Small to K0EPI-2. First try went to A's Winlink answerer, which was on K0EPI-2 (finding 18); after moving Winlink to K0EPI-5, A took it as a file transfer |
| R4b | pass | A received `Photo-20261008-055650.jpg`: 11,743 bytes, 308 × 410, no location. 11:56:33–12:01:36Z, about 41 B/s; 3 of 101 frames resent |
| R4c | pass | A 1 KB file sent from Files: no photo panel; A received `t1k_bin 23.bin`, 1,024 bytes |
| R4d | pass | Two photos picked together got the send sheet one at a time; Cancel moves on to the next as well as Send |
| R5 | pass | Transfer rows show who and when, local and UTC; the sort menu works both ways and keeps its choice |

## Findings

Fixed after the run, test first, with one more rebuild of A (test mode wipes
its settings on every launch).

| # | Where | Finding |
|---|---|---|
| 1 | Mac, radio page | Password entry feels janky: Set… swaps the row for a field that does not get the cursor; Return does not save; Escape does not cancel |
| 2 | Mac, Share a Folder and file description sheets | Return does not press the default button: the text fields take it |
| 3 | Mac, radio page | Saving a password and leaving the page does not connect: the password is in the Keychain, so the settings look unchanged and the reconnect is skipped |
| 4 | Mac, radio chip and sidebar | Connect does nothing for a radio whose link was never created (the password was missing at the first attempt): it only reopens an existing link |
| 5 | Photo sizes | Shrunk photos come out small in pixels (196 × 262 at Small, 251 × 335 at Medium) for their byte budgets; check on the phone at full size |
| 6 | Mac, Settings | Some pages have too much on them (radio page, Packet Node); a pass to trim |
| 7 | iPhone, terminal | The keyboard takes too much of the screen and cannot be hidden |
| 8 | BBS first-call questions | A command typed at once is taken as an answer; "W PARK" was saved as the caller's name, location and home BBS |
| 9 | iPhone | Leaving the app hangs up (DISC from the phone at 11:39:49.556Z), by design for network TNCs; unneeded with the Bluetooth TNC4, which stays up in the background. AX.25 session behavior: needs the operator's approval |
| 10 | iPhone, Session view | A BBS listing reads badly: each line is its own bubble with a header, mixed with protocol frames (`I(6,5)`, `RR`) and RTO notes, and lines wrap at the phone's width |
| 11 | BBS listing | Names are cut to 17 characters and `D` needs the exact name, so a long name (`Photo-20261008-052732.jpg`) cannot be fetched by a caller who only sees the listing |
| 12 | Mac, mailbox header | Says "Off air · Switched on, but not answering" (with "refused: already serving K0EPI-3") during a live call |
| 13 | Mac, BBS transfer row | Progress counts bytes handed to the link, not bytes acknowledged: 100% at 0:21 of a 9-minute download, so "time left" never shows. The phone showed 4% at the same time |
| 14 | iPhone (and likely iPad), transfer view | The operator does not like the transfer view; details to gather |
| 15 | iPhone, TX/RX indicator | Each time "TX" appears the layout jumps to make room for it |
| 16 | Download time estimate | The 90 B/s default quoted 5 minutes; this link ran at about 46 B/s. The measured rate should correct the next listing (R3b) |
| 17 | **BBS downloads (YAPP sender), blocks the park test** | YAPP hands the whole file to the AX.25 link within seconds, queues its end-of-file (EF) behind it and starts its 120-second reply timer then. On a slow link EF does not reach the caller for minutes, so the timer runs out while data is still flowing, and the download is canceled. Any download needing more than about two minutes on the air fails. Same cause as 13 and 16. Fix: feed the link only as it drains (the protocol's `readyForData`), and time the reply from when EF has gone out |
| 18 | Station addresses | Winlink peer-to-peer answering on K0EPI-2 took every connect to K0EPI-2, so a file offer from the phone went into a Winlink session and A never asked to accept it. Moved Winlink to K0EPI-5. Worth warning in Settings when Winlink answers on the station's own address |

## Fixes (2026-10-08, test first; 9,095 macOS tests pass, iOS builds)

| Finding | Fix | Commit |
|---|---|---|
| 17, 13, 16 | Mailbox downloads fed to the link as it drains; acknowledgments count as activity | `5b04d654` |
| 11 | Long names listed whole; `D` takes the start of a name when only one file matches | `e39ea1dd` |
| 8 | A command typed at a first-call question runs and is not saved | `9282ecd5` |
| 9 | Calls stay up in the background on a Bluetooth TNC (operator approved) | `43c7fa81` |
| 15 | TX keeps its room on the status line | `4ca4ce2b` |
| 7 | Terminal keyboard can be hidden (button, scrolling); no autocorrect bar | `b1f5d646`, `c9498c10` |
| 10 | iPhone and iPad Session view reads as a conversation | `c9498c10` |
| 14 | iPhone and iPad transfer card with bar and time left; quieter rows | `39ee11af` |
| 4 | Connect makes a radio's missing link | `6556b8e6` |
| 3 | Saving a password connects the radio | `5703f895` |
| 12 | A mailbox serving a caller shows as on the air | `77348248` |
| 1, 2 | Return and Escape in the password row and BBS sheets | `d89ca049` |
| 18 | Settings warns when Winlink answers on the station's own address | `a3826d01` |
| 5 | No change: a busy 4032 × 3024 photo fits 25 KB at about 335 px; more pixels need a bigger budget (airtime) | — |
| 6 | Not done: which Settings pages to trim is the operator's call |  |

A (705) rebuilt on `a3826d01` (pid 59571) and set up again: IC-705 over Warbler, K0EPI-2, Direwolf off, mailbox K0EPI-4 answering, Winlink K0EPI-5 answering. The phone and iPad reinstalled on `a3826d01`.

## Retest after the fixes (2026-10-08, from 13:13Z)

| # | Result | Notes |
|---|---|---|
| Fixes 1–3 | pass | Password row: the cursor was in the field, Return saved, and A connected without leaving the page |
| R2 | pass | `W PARK` from a caller new to A went straight to the listing (fix 8); one block on the phone, long names on their own lines (fixes 10, 11) |
| R3 | **fail (new cause)** | `D IMG_2820.jpg` from 13:24:29Z. A's row: "2K of 24K · 7% · YAPP · 0:43 · about 9 min left" (fix 17); the phone's card "3 KB of 24 KB · about 7 min left" (fix 14); TX without the line moving (fix 15) |

## More findings

| # | Where | Finding |
|---|---|---|
| 19 | AX.25 links | A holds one link per station, keyed by the caller alone: while the phone's link to K0EPI-2 was up (13:13:48Z), its calls to K0EPI-4 got DM (issue 89's rule). The phone is told nothing about why. Holding a link per address pair is an AX.25 change and needs the operator's approval |
| 20 | Mac, mailbox | The mailbox records why it refused a call (`lastRefusal`), but nothing shows it |
| 21 | iPhone, Transfers tab | The transfer card repeats the row on the Transfers tab; hide it there |
| 22 | iPhone, terminal | The hide-keyboard button (keyboard icon beside Send) was not found; consider a labeled button |
| 23 | **Mailbox idle timeout, blocks the park test** | The mailbox hung up at 13:29:41Z, five minutes into the download, with the phone acknowledging every frame: its idle timeout counted only bytes from the caller, and a caller receiving a download sends none. It also typed its goodbye into the YAPP stream. Stopgap for the run: idle timeout set to 30 minutes on A |
| 24 | **Winlink reply waits** | Found looking for the same pattern across the app: the B2F engine arms its two-minute reply timer as soon as our messages are handed to the link, stretched only by an assumed 50 B/s. A 25 KB photo message on this link would have failed R7 |

## More fixes (test first; 9,103 macOS tests pass, iOS builds)

| Finding | Fix | Commit |
|---|---|---|
| 23 | The mailbox's idle timeout waits while a transfer runs and restarts when it ends; acknowledgments still do not count | `901612fb` |
| 24 | Winlink's reply waits start once our bytes are delivered | `e25a2b27` |
| 21 | The transfer card hides over the terminal's Transfers tab | `f544930a` |
| 22 | The hide-keyboard button reads Done | `43345ab6` |

AXDP needed no change: it feeds chunks on acknowledgments and counts each acknowledged chunk as progress (R4's five-minute transfer finished). The terminal's YAPP was already paced. The iPad has these; the phone was locked; A (705) still runs `a3826d01` and gets them at its next rebuild.

## Retest, continued

| # | Result | Notes |
|---|---|---|
| R3 | pass | With A's idle timeout at 30 minutes: A's call log "downloaded PARK/IMG_2820.jpg" (call from 14:12:55Z). The photo opened full size on the phone; 251 × 335 is good enough for the operator, so the sizes stay |
| R3b | **fail** | `W PARK` on the same call still quoted IMG_2820.jpg at 5m (finding 26) |

| # | Where | Finding |
|---|---|---|
| 25 | iPhone, iPad, Mac | A received file is announced only on its Transfers row (and by a system notification only in the background, with no way to open the file from it). Wanted: a banner with Open and Share in the app, and an Open action on the notification |
| 26 | Mailbox listing | The rate a caller is quoted is read once when the call starts, so a download changes the times only from the next call |
| 27 | iPhone, iPad, terminal | Disconnect hangs up at once and is easy to tap by mistake; it should ask first |

On a fresh call `W PARK` quoted IMG_2820.jpg at 7m, so the download's rate was recorded; only the same call missed it.

| Finding | Fix | Commit |
|---|---|---|
| 26 | A finished download updates the call's rate as well as the station's | `85e7c905` |
| 27 | Disconnect asks first on iPhone and iPad | `07e9f712` |

The phone and iPad reinstalled with everything through `07e9f712`.

| Finding | Fix | Commit |
|---|---|---|
| 25 | A received file brings up a banner with Open and Share (Show in Finder on the Mac); the notification carries the file | `08bd971f` |
| 19 | A refused connect says when a link to another SSID of the same station is up. Holding a link per address pair stays as the spec has it: 86 places look links up by caller, too wide a change before the park test | `7a32c911` |
| 6 | Radio page and Packet Node fold their rarer sections under a closed Advanced row (operator's choice) | `d2f9c244` |

A (705) rebuilt on `d2f9c244` (pid 87465), set up again (IC-705 K0EPI-2, Direwolf off, mailbox K0EPI-4 answering, Winlink K0EPI-5 answering, idle timeout back to its default 5 minutes, which now waits during transfers). The radio page shows the closed Advanced row. The phone and iPad reinstalled on `d2f9c244`.

