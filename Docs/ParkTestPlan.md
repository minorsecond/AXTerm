# Park field test

About 30 minutes at the park using AXTerm the way it will be used in the
field: the iPhone and iPad with the TNC4 and ID-50 at the park, A (705)
unattended at home. Rehearsed at home on 2026-10-08
([run log](SmokeTestRuns/2026-10-08-park-rehearsal.md)).

## Stations

| | **Park** | **Home, A (705)** |
|---|---|---|
| Where | Tollgate Creek Trail by Pioneer Park, Centennial. 39.615928, -104.739856 (DM79po) | 39.612345, -104.733242 (DM79po) |
| Radio | ID-50 on the TNC4, Arrow yagi | IC-705 through Warbler |
| Callsign | K0EPI-3 | K0EPI-2 station, K0EPI-4 mailbox, K0EPI-5 Winlink |
| Devices | iPhone, then the iPad, one at a time on the TNC4 | Mac running AXTerm in test mode |
| Frequency | 145.650 FM, our test frequency | same |

The house is 693 m (0.43 mi) away at **125° true**, about 117° on a compass.
Hold the Arrow with its elements **vertical**, like the home antenna.

On the air this link moves 40 to 80 bytes a second: 1 KB in 15 to 30 s, a
photo at Small (12 KB) in 3 to 5 minutes.

## When to go

A weekday, **about 9:00 to 11:30 am**, while school is in. Timberline
Elementary is 700 m west and Thunder Ridge Middle and Eaglecrest High about
1 km northeast, and their kids use the trail. Second choice: about 12:30 to
2:30 pm.

Avoid 7:15 to 8:30 am and 2:30 to 5:30 pm on school days, weekends (soccer
field and playground), and early evening. Check the Cherry Creek Schools
calendar first: fall break may be October 12 to 16, with kids home all week.

## Before leaving home

| # | Step | Done |
|---|---|---|
| H1 | The Mac stays plugged in with its lid open; Amphetamine on | |
| H2 | The 705 on external power, 145.650 PKTFM. Consider 5 to 10% power: nobody is home to raise it | |
| H3 | A shows "On air as K0EPI-4" in its BBS pane, PARK shared; Winlink answering as K0EPI-5 | |
| H4 | iPhone and iPad: Settings › General › Station position › "This device's location" on, so forms fill in the park's position | |
| H5 | The spreadsheet you will send saved as .xlsx or .csv, not .numbers | |
| H6 | The tune for the video written and saved to Files as .mid (optional, see the finale) | |
| H7 | Phone, iPad and TNC4 charged. Nobody restarts Warbler or A while you are out | |

## The run (about 30 minutes)

Step numbers match the AXTerm Park Test form; mark the form's other steps
SKIP.

| Time | # | Step | Expect | Result |
|---|---|---|---|---|
| 0–5 | Setup | Aim the Arrow, plug the TNC4 into the ID-50. On the iPhone: More › Radios › the TNC4 › Connect | Connected | |
| 5–7 | P1 | Terminal › connect to **K0EPI-2**, send a line, disconnect | Your line goes Waiting to send, Sending, Delivered | |
| 7–12 | P2 | Connect to **K0EPI-4**, skip any first-call questions with `A`, send `W PARK` | The listing arrives and the history follows it | |
| | P3 | Tap **cheat-sheet.txt** in the listing, Send. Then `B` to log off | `D cheat-sheet.txt` fills in; the file arrives in under a minute with a banner | |
| 12–14 | P6 | Transfers › + › Files: your spreadsheet to **K0EPI-2** | Completed | |
| 14–20 | P7 | Transfers › + › Photo Library: one photo at **Small** to **K0EPI-2** | 3 to 5 minutes, no location in it | |
| 20–25 | P8, R1 | Mail › More (…) › Forms › AXTerm › **AXTerm Park Test**: type the setup, mark each step, then Queue for Sending and Exchange › Specific Gateway › **K0EPI-5** | No mailbox call open first. "Exchange complete: sent 1" | |
| 25–30 | I1, I2 | iPhone: More › Radios › the TNC4 › Disconnect. iPad: connect the TNC4, connect to K0EPI-4, `W PARK`, tap a file to download | The banner shows at the bottom on the iPad | |

Fill in P8, R1, I1 and I2 on the form before you send it, or note them and
add them later; the form can be sent again from the iPad.

## Finale: the tune (for the video)

| # | Step | Expect | Result |
|---|---|---|---|
| M2 | Transfers › + › Files: your .mid to **K0EPI-2**. Screen-record the phone while it sends | A few KB, well under a minute | |

At home, A has it in its Transfers folder: Open plays it. No tune written?
Download **morse-cq.mid** from PARK instead (385 bytes). To hear packet tones
in the video, hold the phone near the ID-50: its speaker is muted while the
TNC4 is plugged in. Before posting, leave A's screens and any form's
Position field out of the shot: they show where the house is.

## If something goes wrong

| What you see | What to do |
|---|---|
| A answers (your frames go out) but nothing comes back | The TNC4 is not hearing. Wait a minute, then reseat its cable in the ID-50. Do not restart AXTerm while it is connected to the TNC4 (finding 43) |
| Nothing at all from A | Check the aim and that the Arrow is vertical; move clear of trees. A may have quit at home |
| Winlink "refused the connection" naming K0EPI-4 | A mailbox call is still open. Disconnect from K0EPI-4 and try again |
| The iPad will not connect to the TNC4 | Make sure the iPhone disconnected it in AXTerm. If needed, switch the TNC4 off and on |

## Extras, if there is time

Not needed for the 30 minutes: a message to the sysop (`S K0EPI`, a subject,
a line, `/EX`), a text file to K0EPI-2, the 5 KB Barro tal vez v11.fcpxml,
fortune.txt and pixel-yagi.png from PARK, and a photo from the iPad.

## Afterward

Leave A as it is until you are home. A's database has every frame, transfer
and message; the run log can be written from that and the form you sent.
After the test the 705 goes back to 144.390 PKTFM.
