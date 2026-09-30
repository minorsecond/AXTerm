# Radio Traffic Families

What kind of network each radio is listening to, read from the traffic it has
heard rather than from a setting. `AXTerm/Radio/RadioTrafficFamily.swift`.

One station can have a radio on 144.390 hearing nothing but APRS beacons and
another on a 1200-baud packet channel hearing nothing but node broadcasts and
connected-mode sessions. The two want different things drawn on the map.

## The evidence

Counted per radio, per station, as frames arrive
(`Station.RadioObservation.aprsFrames` / `.sessionFrames`):

- **APRS** — the frame carried a parseable APRS payload: a position, a
  positionless weather report, or a message.
- **AX.25** — the frame was an I, S or non-UI U frame. Those only exist inside
  a session or while one is being set up or torn down.

A plain UI frame counts as **neither**. APRS and a NET/ROM `NODES` broadcast
both ride in one, so counting UI either way would misfile every radio.

**Both counters must be maintained in two places**: `StationTracker.note(...)`
for live packets and `StationTracker.rebuild(from:)` for a bulk reload. The
rebuild originally left them at zero, so a radio reconnect, a replay or a
lifetime-count refresh un-classified every radio — both badges disappeared and
the layer sidebar collapsed back to one flat list.

A radio that has heard nothing classifiable is **absent** from the result, not
present with an empty set. Callers must tell "not known yet" from "neither":
hiding a control for the second reason is how the map goes blank with no way
to bring it back.

## What it changes

### The bug it fixes

"Transmitted Positions" is an APRS idea — show a station at the fix it
beaconed. On a packet channel *nothing* beacons a position, so with the layer
left on (its default), every station on that radio was dropped from the map.
Selecting the Direwolf radio drew nothing at all and reported "0 from beacons ·
23 address-only hidden".

The layer now only governs stations heard on a radio that carries APRS. A
station heard only on a packet channel has no beaconed fix to prefer and is
never hidden for lacking one. A radio with nothing classified yet counts as
APRS, so a fresh session behaves exactly as it did before evidence arrived
rather than briefly drawing a different map.

### The sidebar

Each radio's row carries a small **APRS** / **AX.25** badge, and the map layers
belonging to that family sit under it:

| Family | Layers |
|---|---|
| APRS | Transmitted Positions + the four station-type switches, Movement Trails, Weather Field, APRS Coverage Rings, Objects & Hazards |
| AX.25 | Packet Coverage Rings, Observed Paths, Predicted Paths, Node Directory |
| neither | Drop after, Cluster Markers, Hide Distant Stations |

The packet coverage rings are measured from UA, DM and FRMR replies, which are
connected-mode frames, so they sit with the packet-network layers. The APRS
rings are measured from digipeaters repeating our own beacons. Both kinds also
draw a receive ring (teal) from the stations decoded with no digipeater in the
path, counted only on the radios carrying that family. The two switches used
to share the title "Coverage Rings", which on a single-radio station put two
identical rows in one list.

### APRS-channel radios

A radio marked "on an APRS channel" in Settings (`RadioProfile.aprsEnabled`)
counts as APRS for the map and nothing else, whatever it has heard
(`RadioTrafficClassifier.mapFamilies`). Packet services are locked off on such
a radio, so it can never collect the answers the packet ring is built from,
and its heard-direct stations are the same ones the APRS ring already uses.
Letting it carry AX.25 too produced a second, identical receive ring under a
packet label. The narrowed families drive the layer placement and the
coverage evidence (`MapCoverageEvidence`); the radio row's badges still show
the raw heard evidence.

The case that exposed this was one corrupt frame on a TNC4 (source `V},'-11`,
destination `;Q,C*B-6`) decoded as an I frame. `StationTracker.trafficEvidence`
now requires both addresses to be well formed (one to six upper-case letters
and digits) before a frame counts as session evidence.

### Rings on the map

Two rings built from the same measurement are drawn once
(`CoverageRingSelection.deduplicated`); the survivor stops naming a family. When
rings from both families are on the map, each chip and legend entry carries the
family: "APRS hearing" and "Packet hearing" rather than "Hearing" twice. With
one ring the chip just says "Coverage".

## The station list

The list beside the map goes through the same filter as the markers
(`MapEntryVisibility`). "On the map" is exactly the placed entries that get a
marker, after "Drop after", Transmitted Positions and the station-type
switches. "No known position" is the unplaced entries still inside "Drop
after". A directory lead with no heard time is never dropped by "Drop after";
its own layer governs it.

Each row shows distance and compass direction from our station
("23 mi SSE") when both positions are known, and the packet count as
"61 pkts". The row tooltip omits the distance line when our own position is
unknown.

Our own station is drawn once. Heard entries are removed when their address is
one we have transmitted as (old SSIDs included, from the tx packets in memory),
when they are a sibling SSID of ours placed within 50 m of our position, or
when they are a node alias operated under one of our callsigns
(`HeardStationMap.withoutOwnStation`). A sibling SSID farther away, such as a
mobile or an HT down the street, is another radio and stays.

**A family goes under a radio only when exactly one visible radio carries it.**
A layer switch is one setting and must appear once; two APRS radios would
otherwise each show a "Transmitted Positions" switch bound to the same key,
reading as two independent settings. Families that cannot be filed under a
single radio — several carry them, or nothing has been heard yet — fall back to
the shared **Layers** section, which is also the whole list on a single-radio
station. `MapLayerPlacement.plan` decides this; `MapLayerScope` tells the rows
which subset to draw.

## Tests

`AXTermTests/Unit/Radio/RadioTrafficFamilyTests.swift` — what each frame type
proves, per-radio classification, the mixed channel, the absent-vs-empty
distinction, and every branch of the placement rule including the hidden-radio
and two-carriers cases.

`AXTermTests/Unit/Radio/APRSChannelMapFamiliesTests.swift` — the APRS-channel
rule, its effect on coverage evidence, and the malformed-address guard.
`AXTermTests/Unit/Station/CoverageRingLabelTests.swift` — ring dedupe, chip
labels, legend qualifiers. `MapEntryVisibilityTests`, `OwnStationOnTheMapTests`
and `StationRowTextTests` cover the station list.
