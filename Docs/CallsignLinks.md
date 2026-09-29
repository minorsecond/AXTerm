# Callsigns in the Terminal

Finding callsigns inside message text and making them tappable.
`AXTerm/Analytics/CallsignScanner.swift`, `AXTerm/Station/QRZLink.swift`.

## The two halves

`CallsignValidator` answers "is this token a callsign?" given a token. It has
the patterns, the digit-and-letter rule, the service-endpoint exclusions.

`CallsignScanner` is the other half: which runs of a sentence are worth asking
about, and how sure we are. The addresses either side of the arrow were already
tappable; the body of the line was not.

## Precision, not recall

A 144.390 channel is full of things shaped exactly like callsigns:

```
"`Jb}145.130MHz T088 -060 friesr@yahoo.com_%"
"V:7.32 S:16"
"PHG5370/WA0DE SIMLA digi W2,COn SE Elbert County, CO 13.8V"
Telemetry #074 · 137, 140, 41, 0, 0 · bits 00010011
```

`T088` passes the callsign regex. So does `S9UPPQ`. `W2` sits mid-sentence in a
digi comment. Sending an operator to a QRZ page for a CTCSS tone twice teaches
them never to trust a link in this app again, so the bar is deliberately high
and an uncertain token stays plain text.

Three rules do the work:

**Boundaries.** A token glued to `=`, `:`, `/`, `.` or `#` belongs to a larger
field — a version string, a telemetry value, a frequency, a message number —
and is dropped whole. `PHG5370/WA0DE` yields nothing.

**Enclosures.** Email addresses and URLs are found first and everything inside
them is off limits. This matters more than it looks: the `@` that makes
`friesr@yahoo.com` an email address is the same one that means "addressed to"
in an APRS message, so the two have to be separated here or not at all.

**Evidence.** The strongest signal is not a pattern — it is whether we have
*heard* the station. `PacketEngine.heardBaseCallsigns` is already there, and a
token matching a station this receiver has actually received is a callsign in a
way no regex can argue with. Base calls, not full addresses: hearing `WA0DE-9`
tells us `WA0DE-7` is the same licensee.

## Confidence

| | Means | Linked |
|---|---|---|
| `.heard` | matches a station we have received | yes |
| `.addressed` | `@`-prefixed, the APRS convention | yes |
| `.possible` | matched the pattern and nothing else | **no** |

`scan` returns everything; `links(in:heard:)` returns only what is worth
drawing. A pattern-only match is noticed and left alone — the line between "we
noticed" and "we will send you somewhere".

## Where an address stops

Trailing punctuation is trimmed off a web or email address before it becomes a
link, and the trimmed range is what gets underlined, so the full stop at the end
of a sentence stays in the sentence.

The pair that made this matter is the console's own. `APRSDigestLine` draws a
station's comment inside `“ ”`, so K0RAP-9's beacon — whose whole comment
is a URL — reached the scanner as `http://www.k0rap.com”`. `URL` accepted
that without complaint and encoded the quote into the hostname as the punycode
`xn--com-9o0a`, so clicking the link opened a domain that has never
existed. Nothing on screen gave it away: what was drawn was the comment, and
the quote around it belonged to the console.

## What a tap does

The run is drawn as an `AttributedString` link carrying a private
`axterm-station:` URL. `ConsoleView` intercepts it with an `OpenURLAction` and
opens the station AXTerm already knows about; anything that is not one of ours
is handed straight back to the system, so an ordinary link in a console line
still works.

`AttributedString` rather than a row of separate `Text` views, because the line
has to stay one selectable, wrapping paragraph and splitting it into views
would break both. Underlined rather than recoloured: the console already uses
colour to say what class of line this is, and a second meaning for colour in
the same row would fight the first.

## QRZ

`QRZLink.url(for:)` builds `https://www.qrz.com/db/<CALL>` — no API key, no
subscription, no network call, because QRZ's public profile URLs are just the
callsign. The SSID is dropped: QRZ knows licences, and `KF0YKI-9` is one
operator's ninth station rather than a ninth licensee.

It is a guess, and is offered as one. Service endpoints and tactical aliases
get no link at all rather than one to a page that will not exist.

Two ways to it: right-click a callsign in the console, or the row at the bottom
of the station page. Below everything AXTerm itself knows, deliberately — what
a station has been heard doing is more use mid-session than a licence address.

A real directory lookup is a different thing with a seam of its own:
`CallsignDirectory` and `CallsignDirectoryChain` take HamDB today and would
take QRZ's XML API, an FCC extract or a local cache without either of these
knowing.

## Tests

`AXTermTests/Unit/Analytics/CallsignScannerTests.swift` — every string in it is
real traffic. The telemetry, version strings, PHG data, email addresses and
URLs that must not be linked; the addressed and heard calls that must be; the
pattern-only match that is found but not offered; and the link round trip.

`AXTermTests/Unit/Station/QRZLinkTests.swift` — the URL, the dropped SSID,
normalisation, and the callsigns that get nothing.
