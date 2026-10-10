# The Terminal's console on the Mac

The list of lines on the Terminal page. On the Mac it is an AppKit table,
`ConsoleTableView` in `AXTerm/Console/AppKit/`. iPhone and iPad keep the
SwiftUI list in `ConsoleView`. Both read what a row says from the same place,
`ConsoleLineFacts`, so they agree on links, highlights, chips and tooltips.

## Why a table

The SwiftUI list built each row from views when it scrolled into view and
threw it away when it left. On a busy APRS channel the main thread was 98%
busy while scrolling, and the console stuttered where the Packets table, which
reuses its cells, did not (2026-10-10). Caching the row's text and layout
helped, but most of the cost was SwiftUI laying out and drawing the row views
themselves.

The table keeps a screenful of row views and swaps what they show. A row draws
everything directly, its message included, with its own TextKit layout
(`ConsoleMessageText`). Links are found under the pointer by that layout, and
get the pointing-hand cursor.

To select text, a click into a message puts one `ConsoleSelectionTextView` over
that row (`ConsoleNSTableView.beginSelection`), and the row stops drawing its
own copy. The overlay is a subview of the table, not of the row's cell, so a
cell reused by scrolling never carries it to the wrong row. It goes away when
focus moves on, or before the table changes its rows or its width.

Rows hold no text view on purpose. The first build gave every row one and set
its text when the table built the row. Changing a text view's text moves its
selection, AppKit tells accessibility clients (Magnet, AltTab, a screen reader)
that it moved, and a client that then asks the table for its rows, while the
table is still building this one, makes NSTableView throw. A (705) quit that
way during the park test (2026-10-10). `ConsoleRowTextTests` checks that no row
holds a text view, that drawn links still open, and that the overlay comes and
goes as it should.

`ConsoleScrollBenchmark` hosts the console over 1,000 APRS lines and times a
scroll step. The SwiftUI list took about 5.5 to 6 ms a step; the table takes
0.73 ms. Run it with `TEST_RUNNER_AXTERM_SCROLL_BENCH=1`.

## Heights

A table needs every row's height, not just the rows on screen, so measuring
has to be cheap:

- A row's size comes from a model built without links (`decorated: false`).
  Links and highlights change no sizes. The full model is built only when the
  row comes on screen.
- A line in one fixed-pitch font, where every character has the font's own
  advance, is as wide as its character count times the advance. Most lines are
  like that, and they are never laid out to be measured. The character check
  covers the curly quotes, middle dots and degree signs decoded lines use;
  anything else, an emoji for one, is laid out by TextKit.
- A message that fits its width, with two characters to spare, is one line
  tall. Only a message near or past the edge is laid out at that width.
- Heights are cached per row and width. A new width (the sidebar opening, the
  window resizing) asks for every height again, which is arithmetic for almost
  every row.

`ConsoleTextMeasurer` measures with TextKit 1, no line fragment padding and no
inset, which is how the row's text view lays out. The tests check that the
shortcut heights match a full layout at every width.

## What redraws when

| Change | Effect |
|---|---|
| New lines | Rows are added at the bottom and trimmed at the top (`ConsoleTableDiff`); nothing reloads |
| A row's own content (its time run, a repeat count, a duplicate) | That row reloads |
| A station newly heard, file names seen, link settings | The rows on screen rebuild their links; no heights change |
| Text size, our callsigns, radio tags, units, raw mode | Everything is measured again |

`ConsoleView` hands the table a revision number that changes only when its
rows do. SwiftUI asks the table to update far more often than that, and those
updates are skipped.

## Following the newest line

The rules are `PacketListFollow`, the same ones the SwiftUI list used: at the
bottom, the console follows; scroll up and it stops; new lines then leave the
reader where they are, and getting back to the bottom follows again.

Three details are specific to the table:

- The table tells SwiftUI it stopped following asynchronously. Until SwiftUI
  has applied that, the binding still holds the old value, and the table does
  not read it back. Reading it back is how the first build lost its place
  when the sidebar was toggled.
- A width change while following keeps the view at the bottom. While reading,
  it keeps the reader's row where it was. AppKit goes on settling the view for
  a moment after the width changes, so for a quarter second any shift the
  reader did not make puts their row back.
- The row the reader is on is remembered only when the reader moves the view:
  during a live scroll, or with the content and the view the same size.
  AppKit moving the view while rows change size does not count.

## The status row

Under the last line the console keeps one status row for the session on
screen (`InlineSendStatus`). A line going out shows dimmed until its first
frame reaches the radio, then "Sending…", then "Delivered". A message over
512 bytes gets a progress bar with "Delivered 9.7 of 26.8 KB"; for an AXDP
message it adds that the other station sees it when it has all arrived.
The counts are the session's own: bytes sent for the first time, and the
bytes of each frame the peer acknowledges, so retransmissions, other traffic
and a paclen that changes midway leave them right. The message's own line in
the history is drawn in full color as far as it is acknowledged and dimmed
after that (`ConsoleOutgoingProgress`); an AXDP message stays evenly dimmed
until it is all acknowledged, since the other station cannot read it before.
Until the retest of 2026-10-10 (findings 8 and 9) a long message read
"Waiting to send…" until its last frame had gone, and the counts came from
paclen arithmetic.

A long AXDP message coming in shows "Receiving a message from K0EPI-2… 1.2 of
3.4 KB" until it completes and its text replaces the row. AXDP gives a message
its length in the header, so the size is known from the first frame
(`AXDPStreamReassembler.partial`). Only chat messages show; a file has its own
progress in Transfers. A message going out takes the row first. If the link
ends with a message partway in, the console says how far it got. Before this,
a large block of text from A (705) appeared on the iPad only when the last
frame arrived, with nothing to show it was coming (home retest, 2026-10-10).
`AXDPIncomingProgressTests` covers it.

## Clicks

`ConsoleNSTableView` sends a click on the message to its text view (selection,
links) and anything else to the row: a callsign opens the station, and a row
with duplicates opens or closes them. A right-click on a callsign gives Show
Profile, Quick Look, QRZ and Copy Callsign. Anywhere else on a row it gives
Copy Line, which copies the line as shown.

## Tests

`ConsoleTableTests`: the update plan, the height shortcut against a full
layout, the fixed-pitch width, where a long decoded line goes, session lines,
expanded rows, the row's content and the environment's versions.
`ConsoleTableFollowTests` drives the real table in a window: opening at the
bottom, following, leaving a reader alone, the jump back, and both kinds of
width change.
