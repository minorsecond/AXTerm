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
