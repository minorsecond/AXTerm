# Network Inference

How AXTerm works out the shape of a packet network from traffic alone, and
how it forecasts paths nobody has tried.

Nothing here transmits. Every input is overheard.

---

## 1. Paths — `NetworkPathObserver`

An edge between two stations, graded by what was actually seen. The grading is
the point: presenting a guess and a proven path the same way would turn a
hunch into a recommendation.

| Evidence | Meaning |
| --- | --- |
| `sessionEstablished` | A connect request was answered. Frames crossed in both directions. The only evidence that proves a path end to end. |
| `heardDigipeated` | A frame arrived through this digipeater path, so every hop repeated it. |
| `heardDirect` | A frame was overheard passing directly between the two. |
| `transitive` | Both ends have a working link to the same digipeater. Plausible; never attempted. |

A path is **suspect** when at least two connect attempts went unanswered and
nothing ever completed (`answerWindow` = 120 s, generous against AX.25 T1
backoff). Suspect paths are drawn red — a path that looks plausible and does
not work wastes the most airtime.

Identity is undirected: A→B and B→A are one edge.

---

## 2. Topology — `NetworkTopology`

The graph is built with digipeaters as **their own vertices**, not collapsed
into edge attributes. A digipeater is usually the vertex whose removal breaks
everything, and collapsing it hides exactly the finding worth having.

### Critical stations (articulation points)

Iterative Tarjan — iterative rather than recursive because a long chain of
relays would overflow the stack on a recursive one, and a 5,000-vertex chain
is in the tests to keep it that way.

What surfaces in the UI is never the phrase "articulation point". The
identity page says:

> Everything heard so far reaches 4 stations only through this one. If it
> goes off the air, they go with it.

`partitionsWithout(vertex:)` supplies the sizes behind that sentence.

**What it does not claim.** The graph contains what has been heard. A station
being an articulation point in that graph does not prove no other path
exists — only that none has been observed. The tooltip says so.

### Clusters (label propagation)

Each vertex repeatedly takes the most common label among its neighbours;
ties break alphabetically so a rerun on the same data gives the same answer.
Converges in a handful of rounds at this scale, capped at 20.

This answers the question a network with no NODES broadcasts cannot answer
for itself: *which stations form a local network?* The answer is behavioural
— stations that talk to each other more than they talk outward — rather than
declared.

Determinism matters here. A cluster identity is the alphabetically first
member, so the same group keeps the same name between runs.

---

## 3. Terrain forecasts — `TerrainProfile` and `PredictedPath`

Everything above is a record of what already happened. This is the one part
that says something about a path *before* the first transmission.

### The profile

`TerrainProfile.between(...)` samples the ground along the great circle
between two stations (256 samples by default) and, at each sample, compares
the terrain height against the straight line joining the two antennas.

Three corrections make that comparison mean something:

**Effective earth radius.** The atmosphere refracts VHF downward, so a signal
follows a path slightly flatter than the geometric straight line. The standard
treatment is to pretend the earth is 4/3 its actual radius and keep the ray
straight (`refractionFactor = 4.0/3.0`). The earth's bulge is then subtracted
at each sample.

**First Fresnel zone.** Line of sight is not sufficient. Radio energy travels
through an ellipsoid around the line, and terrain intruding into it causes
loss even with a clear sightline. The radius at a point is

```
r = sqrt(λ · d₁ · d₂ / d)
```

where d₁ and d₂ are the distances to each end. A path is treated as open when
at least **60%** of that zone is clear (`fresnelClearanceThreshold = 0.6`) —
the conventional engineering threshold.

**No-data is not sea level.** A missing sample is `NaN`, never zero. Every
comparison against NaN is false, so a gap cannot pass a clearance test. A
coverage hole reads as `.unknown`, which is drawn as nothing rather than as a
clear path.

### What the numbers actually say

Worth stating plainly, because it surprises people and there is a test
pinning it:

> Two 10 m antennas 13 km apart at 145 MHz clear about **9%** of the first
> Fresnel zone.

That is not a bug. The zone is ~82 m across at the midpoint over that
distance, and two 10 m masts put the line about 7.5 m above the ground after
the earth bulge. Sixty percent clearance over 13 km needs roughly **49 m** of
height. This is why VHF packet lives on hilltops, and why a link can be
line-of-sight on a map and still struggle.

`Outlook` reports three states, and each explains its own geometry rather
than only a verdict:

- `.promising` — line of sight, Fresnel zone essentially clear
- `.marginal` — line of sight, zone intruded on. The "answers but struggles"
  signature.
- `.blocked` — terrain above the line, with how far above and how far along

Blocked paths are a real finding but are **not drawn**: every blocked pair on
a busy map is a mesh of noise. They read as text on the profile instead.

### Antenna height — the input that decides the answer

Height is asked for in three places and stored in metres everywhere:

| Where | What it means |
| --- | --- |
| Settings → Antenna height above ground | This station. The operator always knows it. |
| Settings → Assume for other stations | Every station with no recorded height. An assumption, labelled as one. |
| A station's identity page → Record antenna height | A real height for one remote station. |

Above **ground**, not above sea level — the elevation data supplies the
ground, and adding sea level twice would put every antenna in orbit.

Entry is in feet by default with a ft/m toggle. A US operator knows their mast
in feet, and converting in their head is how a 40 ft tower gets entered as
40 m — a factor-of-three error in the number that decides every verdict.

A forecast with either end assumed is marked `assumedHeights`, and its map
label says "assumed height". A forecast resting on a guess must not read like
one resting on a measurement.

**Gain and antenna type are deliberately not collected.** They do not enter
this calculation at all — Fresnel clearance is geometry, and a 9 dBi
collinear clears exactly as much of the zone as a rubber duck at the same
height. Type and gain would matter to a link budget, which AXTerm does not
compute; collecting them now would be storing data nothing reads.

### Which pairs get evaluated

Candidates are gathered first, then **sorted by distance and evaluated
nearest-first**, and the result budget counts only paths worth *drawing*.

Both details are load-bearing, and getting them wrong drew an empty map.
The first version walked pairs alphabetically and stopped at a fixed count of
*any* result, blocked ones included. In rolling terrain most pairs are
blocked, so the quota was spent long before a workable path was reached — the
map drew nothing while the summary cheerfully reported it had checked sixty
paths. It had; they were the sixty whose callsigns sorted first.

Nearest-first is also the right priority on its own terms: a 9 km path that
works is more use than a 90 km one that might. Ties break on callsign, so the
same inputs always give the same forecasts in the same order.

A separate `maximumProfiles` budget bounds the work, so a large station list
cannot pin a background thread sampling terrain indefinitely.

### When everything is blocked

The common outcome in rolling terrain at modest heights, and it renders as an
empty map. Measured on the real Denver-metro station set: the ground climbs
from ~1600 m at the Platte to ~1790 m at Parker, so a line between two 10 m
antennas has terrain above it and **every** untried path came back blocked.

An empty map is indistinguishable from a broken feature, so the paths menu
always says which it was:

> None clear — closest is AURORA–DENVER, terrain 13 ft above the line

`blockedByMetres` is the actionable number: four metres of obstruction is not
a dead path, it is a path that wants a taller mast. Blocked paths still are
not *drawn* — every blocked pair on a busy map is a mesh saying "no" — but
they are counted and the nearest miss is named.

### Frequency

Forecasts are computed at 145 MHz (`StationsMapView.vhfCalculationFrequency`).
The Fresnel zone narrows as frequency rises, so a path clear at 145 MHz is
clear at 440 MHz — judging the wider zone is the conservative direction.

---

## 4. Elevation data — `ElevationStore` and `ElevationStorage`

USGS 3DEP, public domain, no API key. Downloaded as 32-bit float GeoTIFF,
parsed once, and stored as raw float grids — decoding a TIFF inside a loop
that runs a few hundred times per profile would be absurd.

- One tile per square degree (`tileDegrees = 1.0`); a typical VHF path touches
  one or two.
- 1024 samples per side ≈ 100 m spacing at mid-latitudes — finer than the
  ridges that decide a path, coarse enough that a tile is a few megabytes.
  3DEP's native 1 m data would be four orders of magnitude larger for no
  benefit to this question.
- Bilinear interpolation between samples. Nearest-neighbour puts visible steps
  in a profile and can miss a crest by half a sample.

Downloaded from **Offline Data → Terrain**, next to the basemap, because the
two answer the same operator question from opposite sides: the basemap shows
where a ridge is, the elevation data says whether it is in the way.

**Bounded to the station, not to a bounding box.** `tilesWorthFetching(around:)`
takes tiles within `usefulRadiusDegrees` (1.1° ≈ 120 km) of the operator's own
position — at most sixteen, typically twelve. That radius is not arbitrary: it
is where `PredictedPath` stops evaluating paths, so tiles beyond it answer no
question the app asks.

This is deliberate and load-bearing. The first version handed the downloader a
bounding box of every *placed station*, which is a wildly different thing —
one distant station stretched it across the country and it began fetching a
strip of one-degree tiles from Utah to Virginia, 34 of them and 143 MB, one
polite sequential request at a time to a public USGS service, with nothing in
the UI reporting it. `ElevationStorageTests` pins the bound.

Above `ElevationDownloader.largeRegionTileCount` (6) the download asks first,
showing tile count and size. A full ring is about twelve tiles and 50 MB, so
the common case confirms rather than only the pathological one.

With no tiles stored, terrain features are **unavailable** — the menu item is
disabled and says why. They never guess.

---

## 5. Where this shows up

| Finding | Surface | Why there |
| --- | --- | --- |
| Observed paths | Map, "Observed Paths" | Colour is evidence, dashes are inference |
| Predicted paths | Map, "Predicted Paths" | Purple, dotted, off by default. A forecast is a different kind of claim and must not arrive uninvited alongside a measurement. |
| Forecast outcome | Map, paths menu | Says what the terrain pass found, including "none clear" and the nearest miss — so an empty map is never mistaken for a broken one. |
| Antenna heights | Settings, and each identity page | Own height is a setting because it is always known; a remote height is a note because it usually is not. |
| Critical stations | Identity page, "In the Network" | Consequences in plain words, not graph theory |
| Clusters | Identity page, "In the Network" | The answer to "who is my local network" |

`NetworkInsightModel` computes all three off the main actor and fingerprints
its inputs, so the map re-rendering on every packet does not restart a
terrain pass.

---

## 6. Persistence

Paths derived from the live packet window are folded into `network_paths`
(migration v17) on the same five-second throttle as the service harvest.
Without it the graph is only ever as old as the packets in memory — minutes on
a busy channel — so every launch begins convinced the network is empty. A
packet network is quiet for hours at a time; its shape is not.

Merge rules, in `NetworkPath.merged`:

| Field | Rule | Why |
| --- | --- | --- |
| `evidence` | stronger wins | Proof does not expire because a quiet hour passed |
| `firstSeen` | earlier | The window widens, it does not move |
| `lastSeen` | later | |
| `unansweredAttempts` | larger | High-water mark: a path that failed four times last week is not laundered clean by one window that never tried it |
| `observations` | **larger, not summed** | See below |

`observations` deliberately understates. The observer re-derives from a
rolling window every few seconds, so summing would inflate without bound — a
quiet path recorded often would outrank a busy one. The stored number means
"the most this path was seen carrying in one window", not a lifetime total,
and nothing in the graph reads it as one. Recording the same window three
times is a no-op, which is the property the tests actually pin.

Only *observed* paths are stored. Transitive inferences are re-derived on
demand from whatever the graph holds; storing one would let it harden into a
fact that outlives its evidence.

Retention is a fortnight, pruned when the database opens. A station that moved
away should stop being drawn as a neighbour.

## 7. The station directory

`station_services` had been filling up since the harvester landed with no way
to see it. `StationDirectoryView` (Map toolbar, both shells) lists what each
station runs, grouped by callsign and sorted alphabetically — not by recency,
because a directory is scanned for a half-remembered name and a list that
reorders as traffic arrives cannot be scanned at all.

Every row carries its confidence. `demonstrated` means we watched it repeat a
frame — only digipeating can be proven that way, since nothing a node or BBS
does is visible in a frame header. `declared` is the station's own word from
an ID or beacon, which for most services is the only announcement that will
ever be made.

Filtering by service narrows the rows shown under a station, not merely which
stations appear; showing a station's BBS entry under a digipeater filter would
misreport what the filter did. The picker offers only services something has
actually announced.

## 8. Drawing the terrain

The elevation data decides which paths are called blocked, but until now it
was invisible — an operator was told "there is a ridge 40 m above the line"
and had to take it on faith. The Map's terrain menu draws the same grid the
forecaster reads, in two styles.

**Hillshade** lights the ground from the north-west at 45°, the cartographic
convention. Not an arbitrary one: lit from the south-east the image inverts
perceptually and valleys read as hills. Slope and aspect come from Horn's
method over the eight neighbours, with 2× vertical exaggeration because
true-scale shading at ~100 m sampling is nearly flat grey.

**Elevation** colours absolute height on a **fixed** 0–4500 m ramp. Fixed
rather than per-tile: normalising each tile against its own extremes would put
a seam at every tile boundary and make a flat tile glow like a mountain range.

Three details that would each look plausible while being wrong, and are
pinned by tests:

- A no-data sample stays fully transparent. Painting it as ground would draw a
  flat plain over unknown terrain.
- A sample with any missing neighbour gets no shade at all rather than a
  guessed slope — the edge of a coverage hole is exactly where a fabricated
  neighbour would render a convincing cliff that is not there.
- Longitude spacing shrinks with latitude. Using the latitude spacing for both
  axes tilts every slope on the map.

Tiles are drawn `.aboveRoads` (below labels), one overlay each so MapKit only
renders what is on screen, with the shaded image cached — shading a
1024-square grid is a few million operations and the map redraws on every pan.
The renderer flips the image inside its own rect, without which the terrain
mirrors and the mountains appear east of Denver.

**Rendering cost.** A one-degree tile is 1024 squared — a million samples.
Three things made that take seconds rather than a tenth of one, and all three
were in the inner loop:

- The readable hillshade calls `atan`, `atan2`, `cos` and `sin` per sample:
  four million transcendental calls per tile. Substituting the slope and
  aspect identities collapses it to one square root and four hoisted
  constants. `TerrainShadingTests` checks the fast form against the readable
  one across a spread of gradients rather than trusting the algebra.
- Gathering the eight neighbours through a temporary array allocated once per
  sample — a million heap allocations per tile, costing more than all the
  arithmetic. They are read straight into locals.
- Rows are independent, so the work splits across cores with
  `concurrentPerform`.

Together: about 9x in a debug build, 1.14s to 0.13s per tile.

Shading also no longer happens inside `draw`. MapKit expects a renderer to
return promptly, and computing there froze panning until every visible tile
finished. The first call starts the work on a background queue and returns
nil; `setNeedsDisplay` fires when the tile is ready, so terrain fades in a
tile at a time. Results live in a process-wide `NSCache`, so panning back,
switching styles, or rebuilding the overlay list costs nothing.

**Blended, not painted.** MapKit has no overlay level *beneath* the roads, so
a terrain layer is always on top of them. Painted opaquely it buries the
street grid, the labels and the network lines the map exists for — which is
exactly what the first version did. Hillshade multiplies instead, the way
cartographic relief does: it darkens what is already there rather than
replacing it.

Multiplying only works because the shade is rescaled so **level ground is
white**. Raw hillshade puts flat terrain at cos(zenith) — mid-grey — and
multiplying that darkens the entire map uniformly. Dividing through by the
flat-ground value makes level terrain 1.0, which multiplies to no change, so
only real slopes darken.

Path links are re-added whenever terrain changes. Order within an overlay
level is insertion order, so terrain toggled on after the network would
otherwise cover it.

Packet networks are bridged. A local node linked to the internet — LinBPQ, a
CMS gateway, an APRS-IS feed — puts frames from stations thousands of
kilometres away onto the same stream as the neighbour down the road, and
nothing in a frame distinguishes them.

`StationPlausibility` marks anything further than **300 km** as impossible to
have arrived by radio. The threshold is deliberately generous: real packet
links run to a couple of hundred kilometres from good sites and tropospheric
ducting can carry further, so this catches the obvious cases without ever
quietly hiding a genuine long haul.

A position **inferred from an operator's licence address is never filtered**. A
node on a Colorado hilltop whose licensee lives in Virginia is real and
common, and that distance measures a mailing address rather than a radio path.
Unplaced stations are never filtered either — an unplaced station is usually
the one most worth looking at.

### Downloading a drawn area

The Map's **Download** drawing tool takes two taps — opposite corners — and
opens the offline sheet scoped to that box, for both map tiles and terrain.
Asking for a third corner to describe a rectangle is busywork, and any shape
becomes its own bounding box because tiles are square and a download is a
rectangle. The preview shows the box rather than the tapped points, so what is
about to be fetched is what is on screen.

A download box is a question, not a feature: it gets no name and is never
saved to a layer.

One request fetches at most `maximumTilesPerRequest` (64, about 260 MB). A
hand can draw a continent in two taps — the same shape of mistake that once
had this fetching a strip from Utah to Virginia — and when the cap bites the
sheet says so, naming how many tiles the area actually covers. A cap the
operator cannot see reads as coverage they did not get.

## 10. Stations that arrived down a wire

Nothing is deleted. The filter is off by default, the toolbar control appears
only when there is something it would affect, its tooltip names the stations,
and a banner with a Show button stays on screen the whole time it is on. A
list that silently drops rows is how twenty missing stations stay missing.
