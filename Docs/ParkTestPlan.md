# Park field test

A short trip to the park to use AXTerm the way it will be used in the field:
the iPhone and iPad with the TNC4 and ID-50 at the park, A (705) unattended
at home. Rehearsed at home on 2026-10-08
([run log](SmokeTestRuns/2026-10-08-park-rehearsal.md)).

## Stations

| | **Park** | **Home, A (705)** |
|---|---|---|
| Position | 39.615928, -104.739856 (DM79po) | 39.612345, -104.733242 (DM79po) |
| Radio | ID-50 on the TNC4, Arrow yagi | IC-705 through Warbler |
| Callsign | K0EPI-3 | K0EPI-2 station, K0EPI-4 mailbox, K0EPI-5 Winlink |
| Devices | iPhone and iPad, one at a time on the TNC4 | Mac running AXTerm in test mode |
| Frequency | 145.650 FM, our test frequency | same |

The path is 693 m (0.43 mi). From the park the house is at **125° true**,
about 117° on a compass (declination here is about 7.5° east). Hold the Arrow
with its elements **vertical**: the home antenna is vertical, and a
horizontal yagi loses a lot of signal to a vertical one.

Download rates on this link ran 40 to 80 bytes per second. A rough guide:

| Size | Time on the air |
|---|---|
| 1 KB | 15 to 30 s |
| 5 KB | 1 to 2 min |
| 12 KB (a photo at Small) | 3 to 5 min |
| 25 KB (a photo at Medium) | 6 to 10 min |

## Before leaving home

| # | Step | Done |
|---|---|---|
| H1 | The Mac stays plugged in with its lid open; Amphetamine on | |
| H2 | The 705 on external power, 145.650 PKTFM. Consider 5 to 10% power instead of 0%: nobody will be home to raise it if the phone cannot hear A | |
| H3 | A (705) shows "On air as K0EPI-4" in its BBS pane, Winlink peer-to-peer answering as K0EPI-5 | |
| H4 | Optional: in A's BBS Files pane, tick "Let callers send me files" if you want to try uploading to the mailbox (P9). It is off now | |
| H5 | Spreadsheets saved as .xlsx or .csv, not .numbers. A Numbers document can be a folder on disk, which a file transfer cannot send | |
| H6 | The phone and iPad charged; the TNC4 charged | |
| H7 | Nobody restarts Warbler or A while you are out. If A quits, it comes back without the 705 password or the PARK share and will not answer | |

## At the park

Start on the iPhone. Do the tests in order: each one is a little bigger than
the last, so a problem shows up on something quick. Write down the time (UTC
is fine) and what happened for each; A's database records the frames, and the
run log can be built from both afterward.

### Setup

| # | Step | Expect | Result |
|---|---|---|---|
| S1 | Aim the Arrow at 125° true, elements vertical. Plug the TNC4 into the ID-50 and switch both on | | |
| S2 | AXTerm › More › Radios › the TNC4 › Connect | Connected; the TNC4's settings are read | |

### On the iPhone

| # | Test | Expect | Result |
|---|---|---|---|
| P1 | Terminal › connect to **K0EPI-2**. Type a line and send it | Connected within a few tries. Your line shows dimmed with "Waiting to send", then "Sending", then "Delivered". Disconnect when done | |
| P2 | Connect to **K0EPI-4**. Skip the first-call questions with `A` if they come up. Send `W PARK` | The listing of PARK arrives and the history follows it to the bottom | |
| P3 | Tap **Barro tal vez v11.fcpxml** in the listing, then Send | `D Barro tal vez v11.fcpxml` fills the box when tapped. The file comes down by YAPP in a minute or two and the received banner appears with Open and Share | |
| P4 | Leave a note for the sysop: `S K0EPI`, a subject, a line or two, `/EX` on its own line. Then `B` to log off | "Message N stored.", then `73 de K0EPI-4` on `B` | |
| P5 | Transfers › + › Files: send a **text file** to **K0EPI-2** | The send sheet offers AXDP once A answers the capability check, with compression for text. A takes it; the row turns Completed | |
| P6 | Transfers › + › Files: send a **spreadsheet** (.xlsx or .csv) to **K0EPI-2** | Same as P5. A .csv compresses well; an .xlsx is already compressed and goes at full size | |
| P7 | Transfers › + › Photo Library: send **one photo at Small** to **K0EPI-2** | The photo panel shows Small suggested, the preview, and the airtime. About 3 to 5 minutes. Location left out | |
| P8 | Mail › compose to **K0EPI-5**, a subject, a few lines, and a **photo** (or the spreadsheet) attached. Send it, then Exchange › Specific Gateway › K0EPI-5 | Make sure no mailbox call is open first: A takes one call per station. The exchange console shows the session; "Exchange complete: sent 1" | |
| P9 | Optional, if H4 was done: connect to K0EPI-4, type `U`, and send a small file when it says "Ready — start your upload now." | The mailbox takes the upload into its inbox folder | |

### Write a tune

| # | Test | Expect | Result |
|---|---|---|---|
| M1 | Write a short tune in an app that exports **MIDI** (.mid), and save it to Files | A .mid file of a few KB | |
| M2 | Transfers › + › Files: send the .mid to **K0EPI-2** | AXDP with compression; well under a minute for a few KB. A plays it back later from its Transfers folder | |

### Then the iPad

| # | Test | Expect | Result |
|---|---|---|---|
| I1 | On the iPhone: disconnect any call, then More › Radios › the TNC4 › Disconnect. On the iPad: connect the TNC4 | The TNC4 talks to one device at a time; the iPhone must let go first | |
| I2 | Repeat P1 and P2 from the iPad | As on the iPhone. The received-file banner sits at the bottom on the iPad | |
| I3 | Send one photo from the iPad, by Transfers to K0EPI-2 or by Mail to K0EPI-5 | As P7 or P8 | |

### Reporting results

Fill in results either way, or both:

- **The AXTerm Park Test form**: on the iPad or iPhone, Mail › More (…) ›
  Forms › AXTerm › AXTerm Park Test (on the Mac, the Forms button in Mail).
  Type in the setup, then a pick list for each step and a notes box per
  section. Send it to K0EPI-5 like any Winlink message (P8's steps). Plain
  text, so it is small on the air. Position and grid fill in from GPS when
  Settings › General › Station position › "This device's location" is on:
  switch it on before you go.
- **Park-Test.xlsx** in iCloud Drive › Ham Radio: the same steps as a
  spreadsheet. Sending it back by packet tests a real spreadsheet transfer
  (P6). Export as .xlsx if Numbers converted it.

## If something goes wrong

| What you see | What to do |
|---|---|
| A answers (you see your own frames go out) but nothing comes back | The TNC4 is not hearing. Wait a minute; then reseat the TNC4's cable in the ID-50. Do not restart AXTerm while it is connected to the TNC4: that is what made it deaf twice on 2026-10-08 (finding 43) |
| Nothing at all from A, and the ID-50 shows no signal when you expect A | Check the Arrow's aim and that it is vertical; move to clear the trees. If still nothing, A may have quit at home |
| Winlink says "refused the connection" and names K0EPI-4 | A mailbox call is still open. Disconnect from K0EPI-4 and try again |
| A download crawls | The listing's time estimate should say so. Let it finish or stop it from the transfer card |
| The app is slow or the history stops following | Note the time and what you were doing; both were fixed on 2026-10-08 and should not come back |
| Switching devices and the second one will not connect to the TNC4 | Make sure the first device disconnected the TNC4 in AXTerm. If needed, switch the TNC4 off and on |

## Afterward

Leave A as it is until you are home. Bring back your notes; A's database has
every frame, transfer and message, and the run log for the day can be written
from those and your notes together. After the test the 705 goes back to
144.390 PKTFM.
