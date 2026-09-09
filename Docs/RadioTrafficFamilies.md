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
| APRS | Transmitted Positions + the four station-type switches, Movement Trails, Weather Field, Objects & Hazards |
| AX.25 | Coverage Rings, Observed Paths, Predicted Paths, Node Directory |
| neither | Drop after, Cluster Markers, Hide Distant Stations |

Coverage rings are measured from UA, DM and FRMR replies, which are
connected-mode frames — which is why they sit with the packet-network layers
rather than the APRS ones.

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
