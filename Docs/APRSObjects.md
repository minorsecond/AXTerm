# APRS Objects, Items, Telemetry and Alerts

The non-weather half of what a radio can tell you when nothing upstream works.
Weather is in `Docs/APRSWeather.md`; the inventory of what is and is not
available over RF is in `Docs/WeatherDataSources.md`.

## Objects and items (`AXTerm/APRS/APRSObject.swift`)

A station reports **itself** by beaconing. It reports a fire, a washed-out
bridge, a shelter, an aid station or a landing zone by placing an **object**
(`;`) or an **item** (`)`). Nothing upstream is involved — an operator types it
and a digipeater relays it — so this is the one incident-reporting channel that
survives the grid going down.

```
;WILDFIRE *092345z3947.00N/10505.00W:East ridge, spreading NE
 |_______|| |_____||________________||
 9 chars  |  time   position          comment
          * live / _ killed

)AIDSTN!3944.00N/10448.00WAWater and first aid
 |_____|| name is 3-9 chars, ends at ! (live) or _ (killed)
```

Objects may carry a full weather report, which is how an unattended sensor with
no callsign of its own gets onto the map.

### The rules that make it trustworthy

Three of these are safety rules, not tidiness:

- **Attribution.** An object is a claim by a person, not a measurement. Every
  one carries the station that sent it, and the card leads with it.
- **Only the owner can kill an object.** A kill from any other station is
  ignored. Otherwise anyone on the channel can silence anyone else's hazard
  report by transmitting a kill for its name.
- **Silence is information.** Objects are meant to be re-beaconed while they are
  true, so one nobody has repeated for six hours
  (`APRSObjectStore.liveWindow`) stops being drawn as current. It is kept in
  `expired`, not deleted, so "reported and gone quiet" can be told from "never
  reported".
- **Heard once is marked unconfirmed.** A hazard a station is still repeating
  every ten minutes is being maintained; one heard once may have been a
  passing mobile's guess.
- **The receiver's clock decides age**, never the sender's timestamp.

### Urgency, and why the symbol table matters

`urgency` sorts objects into hazard / notable / marker from the symbol, and it
keys on **table and code together**. `/!` is a police station — somewhere to go
— and `\!` is Emergency. Classifying on the code alone raised a hazard banner
for every sheriff's office on the map, which is precisely how an operator
learns to ignore the banner. An overlay (a digit or letter in the table
position) is an alternate-table symbol and classifies as one.

The list is deliberately short. A list that flags everything flags nothing, and
the actual meaning lives in the name and comment the operator wrote, which are
shown in full and never summarised.

## Telemetry (`AXTerm/APRS/APRSTelemetry.swift`)

How anything that is not weather reaches APRS: creek and river gauges, tank
levels, battery voltage, solar current, generator and pump state. In a
grid-down week "is the creek still rising" and "does the repeater have battery
left" are both answered here and nowhere else.

A `T#` frame carries five integers and eight bits and means nothing on its own.
What the channels *are* comes from three messages the station addresses to
itself — `PARM` (names), `UNIT` (units) and `EQNS` (the `a·v² + b·v + c`
coefficients). Only the station's own definitions are accepted for its own
channels.

**An uncalibrated count is never dressed up as a measurement.** Without an
`EQNS` a reading prints as `137 (raw)`, even when the station has named the
channel and given its unit. A raw count shown as "137 feet" on a flood gauge is
the worst fabrication this app could make. A partial `EQNS` calibrates the
channels it covers and leaves the rest raw.

## NWS alerts (`AXTerm/APRS/APRSWeatherAlert.swift`)

Watches and warnings reach APRS through a gateway (conventionally `WXSVR`) that
reads the NWS feed and transmits bulletins. The RF hop from that gateway to you
survives your internet failing; **the hop from the NWS to the gateway does
not**, and in a real grid-down event the gateway is likely the first thing to
go.

The failure mode is specific: the last product the gateway managed to send
stays on the air, repeated by digipeaters, looking exactly like a current
warning. A tornado warning from six hours ago is a fossil, and nothing in the
packet says which it is.

So every alert carries the time **this receiver** heard it, and shows
`Relayed by WXSVR-5 … — originally from an internet feed`, gaining
"No update since; treat as possibly out of date" past two hours. Stale alerts
are listed rather than dropped: "there was a warning and it has gone quiet" is
different information from "there is no warning".

Classification needs two independent signals — the sender looks like a gateway
**and** the text reads like an alert. Either alone produces false positives: a
station called `NWSMITH` is a person, and a club bulletin joking about a flood
watch is not a warning.

## On the map

Cartography rules that came out of using it:

- **The marker's frame *is* its click target.** MapKit picks an annotation by
  its view's frame and never consults `hitTest`, so overriding hit testing does
  nothing — the frame has to be the target. The view used to be a fixed 96×56
  so the callsign had room underneath, and all of that box selected the
  station. The frame is now the dot plus 4 pt on the Mac (14 pt on iOS, where a
  fingertip is not a pointer) and the label hangs outside it, which costs
  nothing because a label was never meant to be clickable. **If you resize the
  marker, the frame follows it.**
- **A cluster is a composition dial.** Its ring is a donut segmented by what
  is inside — digipeaters, weather, vehicles, fixed — in the four hues the dots
  and legend already use, so a cluster over a ridge of digipeaters reads indigo
  and one over a highway reads amber. The body is paper-coloured with the count
  in ordinary text, so it reads as a container of things rather than a thing.
  That is proportional symbology with a class breakdown, which is how this has
  been done on paper for a century; the flat grey disc that preceded it carried
  less information than the markers it replaced.
- **Clusters are dots, not balloons.** The first version used
  `MKMarkerAnnotationView`, which is exactly what `StationDotAnnotationView`
  had already rejected for stations: it dominates the terrain, covers the
  ground north of the point, puts the true position at the tip rather than the
  body, and drops in with a bounce animation on a map where a moving marker is
  supposed to mean the station moved. A cluster is now a circle in the same
  vocabulary, neutral rather than coloured (the stations inside may be of any
  class and picking one to represent them would invent a fact), sized on a log
  scale, and fading with its freshest member. Clicking one zooms to its
  contents, which is the only useful thing a count can do.
- **Stations fall off.** A "Drop after" setting removes a station once it has
  not been heard for that long. Distinct from the recency fade, which only
  dims: on a busy channel a day of accumulated stations buries the few actually
  on the air, and "who is up right now" is the question this map answers.
- **Clustering is optional and never folds a hazard.** Ordinary stations fold
  into a count when zoomed out; the operator's own station and anything a
  person placed never do, because those are the reasons the page is open.
- **Trails follow the selection.** One trail belonging to the station whose
  card is open needs no legend to identify it. All trails is a switch away, and
  either way the trail is cut to a window the operator sets.
- **The palette is muted.** The system colours are built to be noticed on a
  white sheet; fifty of them over terrain is a field of fluorescent orange with
  a map underneath. Saturation is spent on hazards and the selection.
- **A deliberate layer change bypasses the annotation throttle.** The throttle
  absorbs packet-rate churn, but it also made a layer switch do nothing for ten
  seconds and then apply in a lurch, which reads as a broken toggle.

Hazards and current warnings get a banner across the top of the map, above
every other banner, because they are the reason someone opens the page in an
emergency. It is deliberately narrow — only hazard-symbol objects and only
warnings still being repeated — for the same reason the urgency list is short.

Objects are drawn as their own markers alongside stations; a fire and the
station reporting it are two different points and an operator needs both.
Their site ids are prefixed so an object named after a callsign cannot collide
with the station of that name.

## Tests

- `AXTermTests/Unit/APRS/APRSObjectTests.swift` — the wire formats, the
  table-aware urgency, and every lifecycle rule including the owner-only kill,
  re-raising, and the unrepeated-object window.
- `AXTermTests/Unit/APRS/APRSTelemetryTests.swift` — frames, the three
  definition messages, partial calibration, and the raw-count rule.
- `AXTermTests/Unit/APRS/APRSWeatherAlertTests.swift` — the two-signal
  classifier, severity ordering, and staleness.

## Placing and standing down

Until now this layer was read-only. Placing an object is the only map action
that keys the radio on the operator's behalf, and it writes into a namespace
shared with every other station on the channel, so the affordance is built
around the two things that can go wrong socially rather than technically.

**Input, on macOS.** Secondary click on open map. `buttonMask 0x2` is the
right button, which is also what AppKit reports for a two-finger trackpad
click and for Control-click, so all three work without asking the operator
which they have. It is suppressed while a drawing tool is active — the drawing
tools own the map then — and over a marker, where the click means that
station. There is no iOS equivalent and none is approximated: a long press
there already means something else.

**Not the same thing as Mark.** The drawing strip's *Mark* saves a shape to a
scratch layer on this device. An object transmits. The two are deliberately
separate affordances with separate wording, because an operator who thinks
they are drawing a private note and actually keys the radio is the worst
outcome this feature has.

**Name collisions.** APRS keys objects by name alone across the whole channel,
with no authentication anywhere in it. Transmitting an object named `AID` when
another station already has a live `AID` replaces theirs on every receiver in
range — in an incident net, one agency's marker silently overwriting another's.
`APRSObjectPlacement.problem` catches that before the button enables, matching
case- and padding-insensitively because that is how the key works everywhere
else. Re-sending *our own* name is not a collision: it is how an object is
moved or its comment corrected, and the format offers no other way.

**Moving one.** APRS has no move. Re-transmitting under a name we already own
*is* the move, and every receiver replaces what it had — which is why
`APRSObjectPlacement.problem` treats our own name as no collision, and why
without that check there would be no way to move anything at all.

It is armed from the object's own card and finished with the ordinary
secondary click, not by dragging the marker. A drag that transmits is one
slipped trackpad away from moving somebody's road closure by accident and there
is no undo on a shared channel; routing it through the same sheet keeps the step
where nothing keys the radio until the operator presses Transmit. The armed
state gets a banner with a Cancel, because a mode you cannot see is one you
cancel by clicking somewhere else — and here clicking somewhere else transmits.

The sheet opens pre-filled, which means recovering the choice from the two
symbol bytes (`Choice.matching`). `APRSObjectSymbolTests` holds that every
offered symbol round-trips; one that did not would come back as the fallback and
silently change what the channel sees, which is the failure the symbol table
exists to prevent.

**Whose object may be stood down.** APRS honours a kill from anyone. The
button is offered only for our own anyway, because an operator who can stand
down another agency's road closure with one click will eventually do it by
accident. The help text says a kill is a transmission and not a local delete,
or the operator expects the wrong map to change.

**The kill byte, and what receivers do with it.** `_` in place of `*` is the
whole difference between an object standing and an object gone, and it is
settled against Xastir rather than against our own parser. `extract_object()`
(`src/db.c`) takes the first nine characters as the name and leaves `info` on
the state byte; `_` reaches `delete_object()`, which clears `ST_ACTIVE` and
`ST_INVIEW` so the object stops being drawn. There is no check of who sent it —
which is why the owner-only rule on our Stand Down button is ours and not the
protocol's. Direwolf cannot settle this one: its summary line describes a kill
exactly as it describes a placement.

Receiving a kill and *acting* on one are separate questions. On air on
2026-09-09 a placement and its stand-down both went out from K0EPI-7, both were
repeated by WQ8M-9 and AD1CT, and aprs.fi for iOS logged both frames in its raw
packet list and left the marker on its map. Xastir's source carries the same
complaint about its own display — `// ?? does not vanish from map immediately
!!???` beside the `delete_object()` call, and `// there is some problem...  it
is not redrawn immediately!` inside it. A kill that changes nothing visible on
the far end is not evidence that the kill was malformed.

**Our own object on our own map.** Transmitted frames never enter the packet
log, so `SessionCoordinator.sendAPRSObject` tells `APRSObjectStore` directly.
Without that the operator places a closure, the sheet dismisses, and nothing
appears — the same silence the pending-transmission work exists to remove.

**One frame, once.** Objects are conventionally re-beaconed while they remain
true. Doing that on a timer is a decision about occupying a shared channel
that belongs to the operator, not to a default, so it is not done;
`liveWindow` expires an unrepeated object after six hours, ours included.

A stand-down is the exception, because there the asymmetry runs the other way.
A placement that fails to arrive is visible to nobody and harms nothing; a kill
that fails leaves the object standing on every receiver that heard the
placement, with nothing to clear it until `liveWindow` runs out — and the
operator who sent it has no way to tell. So `APRSObjectKillRepeat.ladder`
repeats it at 60 s, 120 s and 240 s: four frames over seven minutes, then
silence. Bounded news, not a claim being maintained.

Two things about that ladder are not adjustable by taste. **Nothing in it is
shorter than a minute**, because an object timestamp is `DDHHMMz` — minutes, no
seconds — so two kills inside one minute encode to byte-identical frames and a
digipeater's duplicate suppression (Direwolf's `DEDUPE`, 30 s by default) drops
the second; a repeat nobody repeats is not a repeat. Each repeat is therefore
**rebuilt at the moment it goes out**, not replayed. And **a queued repeat is
abandoned the moment anything is live under that name again** — ours or a
stranger's. Stand down `AID`, place `AID` again, and a repeat still in the queue
would kill the new one on the whole channel; if the name was taken by another
agency in the gap, it would remove theirs and nothing here would ever say so.

The repeats are silent. The stand-down is announced once, up front, and says
that it will repeat — the operator is the one answering for a few minutes of a
shared channel — but four notifications saying the same thing would be noise
when the traffic log already shows every transmission. They live only as long as
the app: a stand-down interrupted by a quit is one transmission, which is what
it was before any of this existed.
