# APRS in the Terminal

What the terminal prints when a frame turns out to be APRS, and why it is not
the frame itself. `AXTerm/APRS/APRSDigest.swift`, `APRSDigestLine.swift`.

## The problem

The console printed `packet.info` verbatim. For AX.25 that is the right answer
and it stays the right answer: a NET/ROM broadcast, a BBS prompt and an I-frame
payload are all readable as sent, and the terminal is where an operator goes to
read them.

APRS does not survive the same treatment. A Mic-E position keeps its latitude
in the AX.25 **destination** field and the rest in bytes that are not text:

```
1:10:58 PM  KF0KBL-1 → SYUUUU   `q[Qm"[>/`"E^}_4
```

Nobody reads that. The row also draws `SYUUUU` as though it were a callsign,
which it is not — it is a latitude. Compressed reports are no better. So on a
144.390 channel the terminal was printing the one class of frame it could not
print, and doing it for almost every line on the screen.

## What it does now

A frame that decodes as APRS is rendered as a sentence, with its symbol beside
it:

```
1:11:55 PM  WA0DE-9 → APMI0  ⌂ 39.3935, -104.6748 · 12.4 mi SW · 45 mph at 210° · "APRS Voyager"
```

Frames that are not APRS are untouched.

## The decode is shared

`APRSDigest.parse(destination:info:)` returns the existing parsers' own types —
`APRSReport`, `APRSWeather`, `APRSObjectReport`, `APRSMessage.Inbound`,
`APRSTelemetry.Frame` — rather than a parallel set. There is one implementation
of "what is a Mic-E position" in the app, so the console cannot drift from the
map.

It takes **bytes**, never `Packet.infoText`. That string has already trimmed
control characters and given up on anything under three-quarters printable,
which is exactly what a Mic-E payload is; a digest built from it would miss the
frames that most need decoding.

Order matters where data types overlap: an object report ends in position data,
and a weather-carrying position is a position first.

## Where it is computed

Once, in `ConsoleLine.init`, and stored. `body` runs for every visible row on
every pass of the console's update, and re-parsing a Mic-E position there would
be work per row per render on a list that grows all day (CLAUDE.md §12).

`ConsoleLine` keeps the information field alongside the digest, and
`ConsoleEntryMetadata` persists it as base64. A reloaded transcript therefore
reads exactly as a live one, and an improvement to the decoder reaches old
lines instead of leaving the history rendered by whichever version was running
that day. Roughly eighty bytes per APRS line, on a bounded buffer.

`ConsoleLine` hashes on its id: the synthesised conformance would need every
member to be `Hashable` and `APRSObjectReport` is not, and a UUID is the better
hash regardless — two lines with the same text a second apart are different
lines.

## Comments that are not comments

Three things the terminal used to print as though they were the operator talking.

**Fields the parser had already read.** A Mic-E payload carries a type code
naming the radio's family (`]` a Kenwood TM-D700/710), an altitude in base-91,
and often a repeater listing. All three used to stay in `comment`, so a line
printed the altitude twice — once as `5,587 ft` and again as `"FX}` mid
sentence. `parseUncompressed` had always stripped `/A=`; Mic-E was the path
that did not, which is why the Direwolf cross-validation covered the other two
encodings and not this one. It covers Mic-E now too.

**The radio's signature.** The type code opens the status text; one or two
characters at the very end close it, naming the model within that family — `_4`
a Yaesu, `|3` a Byonics TinyTrak3, `=` a Kenwood TM-D710. How many characters
it is depends on which family the type code named, so the two ends have to be
read together: a Kenwood signs with one, a Yaesu or a Byonics with two, and a
radio that gave no type code does not sign at all.

Left in, the signature runs straight into whatever the operator wrote last.
`http://www.k0rap.com` arrived as `http://www.k0rap.com_4` and the terminal
linked it to a punycode hostname that does not exist; a TM-D710 with nothing to
say showed a comment of `"="`.

This is the one place the console goes further than the Direwolf recording. The
`decode_aprs` that produced the fixture ran without its `tocalls.yaml`, so it
could not identify the radio and kept the signature; with that table loaded it
takes off exactly what we take off. `APRSZooTests` says so where it asserts it.

**Bytes that are not text.** A TM-D710 pads its status field to a fixed length
with `FF`:

```
145.190MHz      -060<FF>…×18…<FF>=
```

Neither ASCII nor UTF-8, so every one decodes to U+FFFD and the line ended in a
row of replacement glyphs. It is the sending radio's padding, not damage —
two receptions arrive byte-identical. `APRSDigestLine` drops them at the
display layer only: the parser keeps what arrived, the tooltip prints every
byte as `<FF>`, and RAW shows the frame as sent.

## Repeater listings

`APRSFrequencySpec` reads `FFF.FFFMHz`, an optional tone and an optional
offset off the front of a comment, so

```
145.190MHz      -060=
147.210MHz C100 +060_1
```

read as `145.190 MHz · -600 kHz` and `147.210 MHz · CTCSS 100.0 · +600 kHz`.

Anchored at the start deliberately: that is where the structured field lives,
and "net at 147.210MHz Thursday" is somebody talking.

The tone field is the standard tone with its decimal dropped and the fraction
truncated — 88.5 is sent as `088` — so it is looked up in the EIA/TIA table
rather than divided by ten. No two standard tones share a whole-number part,
which makes the lookup exact; a field that is not on the list gets no number
invented for it, because an operator will dial in whatever we print and wonder
why the repeater stays shut. The offset is sent in units of 10 kHz and shown in
kHz: `-060` is the standard 2 m −600 kHz.

## What a digi says about its reach

The seven bytes after the symbol are a data extension, and on this channel the
stations that use it are the digipeaters. `APRSCoverage` reads the three that
are not course and speed:

```
PHG3830     9 W · 2,560 ft HAAT · 3 dB · omni
PHG58306    25 W · 2,560 ft HAAT · 3 dB · omni · 6/hour
RNG0050     50 mi claimed
DFS2360     hears S2 · 80 ft HAAT · 6 dB · omni
```

Four digits on four different scales, which is why the raw field reads as a
serial number: power is the digit *squared* in watts, height is `10 × 2^h`
feet above average terrain, gain is plain dB, and directivity is a bearing in
45° steps with 0 meaning omni. `DFS` is the same four for a receive-only site,
where the first digit counts what it hears in S-points instead of what it
sends. The eighth character, when it is a digit, is the beacon rate the later
PHGR convention added — BADGR sends `PHG58306`, and unread that `6` ends up
glued to the front of the comment.

Read in its own slot and nowhere else. QUAIL sends `# 12.1V 99F PHG2820 W2,COn`
— a voltage where the extension goes — so nothing is lifted and the comment
stays whole. Course and speed occupy the same bytes and are tried first: a
moving station is not describing an aerial.

This is the station's own claim, and it stays separate from `CoverageEstimate`,
which is measured from who actually answered us. `W2,COn` alongside it is not a
field at all — it is the digi naming the aliases it repeats, in the operator's
shorthand, and it belongs in the comment where it was written.

## Altitude that is a digit short

`/A=aaaaaa` is six digits in the spec and six in almost every beacon. WA6IFI-6
sends `/A=12349`, and a reader that insists on six prints the field in the
comment and leaves the altitude column empty for a station at twelve thousand
feet. The digits are taken as they come, up to six; `/A=` with nothing
countable after it is still not an altitude.

## Telemetry

`T#217,137,140,41,0,0,00010011` is thirteen channels: five analogue counts and
eight digital lines the operator wired up. What they mean lives in four
messages the station sends every few hours, addressed to itself:

```
PARM.Vin,Rx1h,Dg1h,Eff1h,A5,O1,O2,O3,O4,I1,I2,I3,I4
UNIT.Volt,Pkt,Pkt,Pcnt,None,On,On,On,On,Hi,Hi,Hi,Hi
EQNS.0,0.075,0,0,10,0,0,10,0,0,1,0,0,0,0
BITS.11111111,WX3in1Plus20 Telemetry
```

`StationTracker` already collected these into `Station.telemetryDefinition`,
but only the station card used them; the console had no definition in hand and
`APRSTelemetry.bitReadings` had no caller at all. `PacketEngine.telemetryDefinitions`
now carries them to the line, keyed by **full** callsign — a station's
telemetry belongs to that SSID's hardware, and `-1`'s channels are not `-9`'s.

The calibration is the point, not decoration: `Rx1h` has `b = 10`, so 140
counts is **1400 packets**. A line printing the raw count would be wrong by a
factor of ten. Where a channel has no `EQNS`, `Reading.text` marks it `(raw)`
rather than dressing a count in units it has not earned. A station that names
none of its digital lines keeps the bit string, because eight repetitions of
"channel six is off" say less than `00010011` does.

## DAO and folded telemetry

Two more structured fields hide in comments, and both were confirmed against
Direwolf's `decode_aprs` rather than from the specification alone — a
refinement applied with the wrong scale or sign puts a station in the wrong
place.

**`!DAO!`** (APRS 1.2 ch. 6) carries the digits past hundredths of a minute,
taking a fix from about 18 m of quantisation to under a metre:

```
!3933.48N/10447.63W … !w+K!  →  N 39 33.4811, W 104 47.6346   (base-91)
!3933.48N/10447.63W … !W12!  →  N 39 33.4810, W 104 47.6320   (digits)
```

Lowercase datum: each character is a 91st of one hundredth of a minute.
Uppercase: each is the next decimal digit, a thousandth of a minute. Added to
the **magnitude**, so a west longitude gets more negative.

Exactly three characters between the marks. That rule is what keeps N1ROG's
`!SN!` — two characters, sent twenty-eight times in one evening — from being
read as a position refinement and walking the station sideways.

**Base-91 comment telemetry** (ch. 13) folds a whole report into a comment so a
tracker need not spend a second packet: `|!%%v(3|` is sequence 4, channels 449
and 655, which is what `decode_aprs` reports for the same frame. Only a
well-formed run is read — base-91 characters, an even count, a sequence plus
one to five values. Several trackers here emit a stray `|3` after their DAO;
Direwolf leaves that as text and so do we, because a lone pipe is not a report
and guessing at one invents readings.

## Classification

A decoded frame is filed by what it turned out to be, not by how its text
reads:

| Frame | Chip |
|---|---|
| position, weather, object, telemetry, status | **BCN** |
| message, bulletin | **DATA** |
| ack, reject, directed query, general query | **CMD** |

This is the other half of the problem. `detectMessageType` sorts anything over
ten characters into DATA, and every APRS beacon is over ten characters — so on
a channel with 84 stations there was no way to quiet the beacons without hiding
the conversation with them. Positions are beacons; filing them as beacons makes
the BCN chip do what its name says.

## The wire is always reachable

Two ways, because this is a terminal:

- **Hover** a decoded line. The tooltip shows the information field byte for
  byte, printable characters as themselves and everything else as `<1C>` — the
  bytes that matter most in a Mic-E frame are the ones that are not text, and
  rendering them as replacement characters would hide what the tooltip is for.
- **The RAW switch** on the filter row prints APRS frames as they arrived.
  It sits apart from the class chips and the MINE/DIGI narrowing switches
  because it is neither: it changes how lines are printed, not which ones are.

## Distance

`observer` comes from `StationPositionResolver.ownStation` — the same resolver,
the same three preference keys and the same unit setting the map uses, so
"12.4 mi SW" means the same thing on both surfaces. When the station has no
position set and no fix, the coordinates stand alone; no distance is invented
from a grid square nobody entered.

## Tests

`AXTermTests/Unit/APRS/APRSDigestTests.swift` — the Mic-E frame that could not
be printed, an uncompressed position with a comment, messages, acks, status,
telemetry, both unit systems, distance present only with an observer, non-APRS
frames left alone, and the classification split that lets BCN quiet a channel
without hiding its messages.

`AXTermTests/Unit/APRS/APRSCoverageTests.swift` — PHG, the PHGR rate digit, RNG
and DFS; the slot rule, with QUAIL's voltage and a moving station's course and
speed as the two ways not to read one; and the short `/A=`. Every beacon in it
but the two synthesised ones was heard on the operator's own channel.
