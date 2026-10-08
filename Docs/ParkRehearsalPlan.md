# Park test rehearsal

**2026-10-08.** A short on-air run at home of everything added for the park
field test, before relying on it away from the station. It covers photo
sizing with a preview, airtime and download times, local and UTC times with
sorting, and the BBS as callers see it. Results go in the Result column as
each test runs.

## Stations

| | **A (705)** | **Phone / iPad** |
|---|---|---|
| Role | BBS and Winlink host | Caller, as at the park |
| Radio | IC-705 through Warbler (`localhost:50100`), low power | ID-50 on the Mobilinkd TNC4 over Bluetooth |
| Callsign | K0EPI-2 (station, Winlink peer-to-peer), K0EPI-4 (mailbox) | K0EPI-3 |
| Frequency | 145.650 FM, our test frequency | same |
| Build | `b0868b31` (everything below except the Connect fix `ef448a00` and the photo library in Send File, which is iOS only) | `2680c8b8`, installed 2026-10-08 |

The TNC4 talks to one device at a time. The phone runs R2 to R6 first; then
the operator disconnects the phone in AXTerm and connects the iPad for R7 and
R8.

## Rules

1. Transmit only for these tests, on 145.650, at low power.
2. Never save settings to the TNC4's memory.
3. A (705) is ended only by pid, never by pattern.
4. A failure is noted with what was seen, fixed test first, and run again.
5. After the run, A (705) stays on 145.650 with its mailbox answering for the
   park test, unless the operator says otherwise. After the park test it goes
   back to 144.390 PKTFM.

Who: **C** Claude, **Y** the operator, **C+Y** both.

## Before starting

| # | Step | Who | Result |
|---|---|---|---|
| P1 | A (705) connected through Warbler, the 705 reads 145.650 PKTFM | C | |
| P2 | A's mailbox answers calls as K0EPI-4 (Settings > BBS) | C | |
| P3 | A answers Winlink peer-to-peer as K0EPI-2 (Settings > Winlink) | C | |
| P4 | A has a BBS file area to add to: the BBS pane > Files > Share a Folder, picking `~/Documents/AXTerm-BBS-Park` | Y picks, C checks | |
| P5 | The phone and iPad each have two or three camera photos in Photos, one of them also saved to Files, and one photo is on the Mac | Y | |
| P6 | Note A's pid, to tell later whether it quit by itself | C | |

## Tests

### Mac (A)

| # | Test | Who | Expect | Result |
|---|---|---|---|---|
| R1 | In A's BBS Files pane, select the area and Add Files: pick one phone photo (several MB) and one text file | Y picks, C checks | The text file goes in at once. A Photo Size sheet opens for the photo: the preview reads "As it will arrive", press and hold shows the original, sizes switch and the summary updates (size, pixels, airtime). Add puts it in at the chosen size; the original on disk is unchanged | |
| R1b | Drag the same photo onto the area's file list from Finder | Y | The same sheet opens. Skip leaves the photo out and says nothing went in for it | |
| R1c | The Files list for that area | C | Each file shows Size and On air; with no caller on the air, On air is at 90 B/s | |

### Phone

| # | Test | Who | Expect | Result |
|---|---|---|---|---|
| R2 | Connect to K0EPI-4 and list the area with `W <area>` | Y | The NAME / SIZE / TIME table arrives. TIME is at 90 B/s (no transfers yet in this run). A's live call transcript shows the same table | |
| R3 | `D <photo>` to download the photo added in R1 | Y; C watches A | A's transfer row shows bytes, percent, YAPP, elapsed, and after 10 s "about N min left", counting down. The phone saves the photo and it opens, at the size picked in R1 | |
| R3b | `W <area>` again on the same call | Y | TIME now reflects the rate the download actually ran at (a new call is needed if the shell keeps its rate per call; note which) | |
| R3c | A's Files list during the call | C | On air matches the caller's TIME for each file | |
| R4 | Disconnect. Transfers > + asks Photo Library or Files; choose Photo Library and pick one photo, to K0EPI-2 | Y | The send sheet opens with the photo named Photo-<date>-<time>.heic. The photo panel shows Small (suggested), the preview, press and hold for the original, each size updates the summary and the airtime line. Keep the photo's location is off | |
| R4b | Send it at Small | Y; C checks A | A receives it. Its size and pixel size match the panel's summary. The photo has no GPS position | |
| R4c | + > Files: send the photo saved to Files, then a text file | Y | The Files photo gets the same photo panel. The text file gets no panel, and an airtime line shows under it | |
| R4d | + > Photo Library: pick two photos at once | Y | Each gets the send sheet in turn, numbered -1 and -2 | |
| R5 | Transfers list on the phone | Y | Each row says "To K0EPI-2" or "From K0EPI-2", then the local time and the UTC time. The sort menu (↑↓) sorts by Time, Name, Station and Size, both ways, and is still set after leaving and coming back | |
| R6 | Photos share sheet: does AXTerm appear for a photo? | Y | Record what is offered. Not needed for the park now that Send File reaches the library | |

### iPad

| # | Test | Who | Expect | Result |
|---|---|---|---|---|
| R7 | Mail > compose to K0EPI-2, add a photo with the Photos button | Y | The photo is attached already shrunk (Medium, about 25 KB). The footer shows the size and "~N min on air" | |
| R7b | Tap the photo's chip (or Photo Size… in its menu) | Y | The size panel opens at Medium, with the preview and press and hold for the original. Pick Small, Done: the chip and the footer airtime update | |
| R7c | Send the message peer-to-peer to K0EPI-2 | Y; C checks A | A receives it with the photo at the Small size | |
| R8 | Mail list on the iPad (Sent folder) | Y | Each row shows its date and, under it, the UTC time. The sort menu by the search field sorts by Date, Correspondent, Subject and Size, both ways | |
| R8b | The photo panel on the iPad's wider screen, both orientations | Y | Nothing clipped or overlapping; the preview fits | |

### Lists on the Mac (A), after the traffic above

| # | Test | Who | Expect | Result |
|---|---|---|---|---|
| R9 | Winlink table (Inbox) | C | Date (local) and UTC columns, full time in the tooltip. Clicking a column header sorts by it; the sort menu agrees | |
| R9b | Transfers list | C | The who-and-when line on each row; the sort menu works | |
| R9c | BBS messages pane | C | Each message shows local and UTC; the sort menu beside the filter sorts by Received, From and Subject | |
| R9d | APRS messages, if any traffic | C | Each conversation shows its last message's time in both; the sort menu sorts by Last Message and Station | |

## Closing

| # | Step | Who | Result |
|---|---|---|---|
| X1 | A's pid is the one noted in P6: it did not quit by itself during the run | C | |
| X2 | Failures, if any, fixed and run again | C | |
| X3 | The TNC4 back on the ID-50's everyday settings (AXTerm restores them on disconnect; nothing was saved to it) | Y | |
| X4 | A (705) left on 145.650 with the mailbox answering for the park test, or back to 144.390 if the operator says | Y | |
