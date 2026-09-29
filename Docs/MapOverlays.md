# Map Overlays

Vector data over the basemap: county lines, ARES districts, evacuation zones,
flood polygons, and positions the operator marks themselves.

The basemap (`Docs/OfflineMaps.md`) answers "what is the terrain here". These
answer "what are the boundaries that matter to this activation".

---

## 1. Reading

**Shapefiles**, because that is what agencies hand out. An operator given a
`.zip` from an EOC has a shapefile, not GeoJSON, and telling them to convert it
first is telling them to find a computer with GDAL on it during an activation.
`ShapefileReader` reads points, polylines and polygons, including the Z and M
variants — a boundary with elevations is still a boundary.

**GeoJSON**, through MapKit's `MKGeoJSONDecoder`, converted into the same
feature model so the rest of the app draws one representation rather than two.

Attributes are carried, not discarded. A polygon is not "a polygon", it is
"Evacuation Zone C" or "Douglas County"; a layer that draws unnamed shapes is
a decoration.

### The two traps

**Coordinate order.** In a shapefile x is longitude and y is latitude, in that
order. Swapping them puts a Colorado county off the coast of Somalia — with no
error.

**Projection.** A `.shp` carries no coordinate system; the numbers are just
numbers. If the companion `.prj` says State Plane feet and they are read as
degrees, every feature lands thousands of miles away, silently. So the `.prj`
is read: geographic WGS 84 or NAD 83 is accepted, a projected system is refused
*by name*, and a missing `.prj` is accepted because most agency downloads have
none and are lat/lon.

### Refusing rather than half-drawing

- A truncated record **stops the read**. A partially-drawn evacuation boundary
  is indistinguishable from a complete one, and somebody may plan around it.
- Unsupported geometry is **named**, not skipped.
- Null shapes are skipped — a legal record meaning "no geometry here".
- Polygon holes are kept. Dropping them draws a solid county over a lake.

---

## 2. Persistence

Layers are stored as **GeoJSON files** in Application Support, not rows in the
database. Three reasons, in order of weight:

1. **A layer is worth nothing if it vanishes on quit.** An operator who loaded
   county boundaries before an activation needs them during it, and the
   activation is the part where nobody has a spare hand to re-import anything.
2. **It is the same format they export and send.** One writer, one reader, and
   the file on disk is already the file to attach — no second serialisation to
   keep in step with the one that goes over the air.
3. **A layer is a file the operator brought.** Keeping it as a file means they
   can take it away again, and a corrupt layer costs one file rather than the
   mailbox it would have shared a database with.

A shapefile is converted to GeoJSON once, on import, rather than re-parsed on
every launch.

Colour and visibility live in a `.display.json` sidecar so the `.geojson` stays
a clean standard file any other tool can open — putting AXTerm's display
preferences in its properties would make every exported file carry app-specific
noise.

A file that will not parse is reported and skipped rather than stopping the
load: one bad layer must not cost the other five, and the operator needs to
know which one to replace.

**Not synced.** An overlay is a working file for one activation, often
megabytes; pushing a county shapefile through the mailbox's sync channel would
be expensive for no gain. Same reasoning as `Docs/UnifiedMailbox.md` §2.

---

## 3. Drawing and editing

Three tools, in a strip that appears only while drawing — a permanent toolbar
would suggest the map is a drawing surface first, when it is a station map that
can also be drawn on.

| Tool | Needs | Finishes |
|---|---|---|
| **Mark** | 1 tap | immediately |
| **Line** | 2 points | Done |
| **Area** | 3 corners | Done, and closes itself |

Taps land anywhere on the map and are converted with
`MKMapView.convert(_:toCoordinateFrom:)`. The tap recogniser runs
*simultaneously* with MapKit's own, so panning and pinch-zoom keep working
while drawing, and a tap that lands on a station marker is ignored — the
operator meant to look at the station.

`MapDrawingSession` holds the rules and is tested without tapping anything.
Below the minimum, it refuses to produce geometry rather than emitting
something degenerate: a two-point "area" and a one-point "line" are handled
differently by the shapefile writer, GeoJSON and MapKit's renderer, and none
handle them well. The progress text says what is still needed, because a
disabled Done button the operator cannot explain is worse than one that says
what it is waiting for.

An area's ring is stored **open** and closed on write — a ring closed twice has
a duplicated point some readers report as a degenerate edge. The live preview
*does* show the closing edge, so the operator sees the shape rather than the
open path they have tapped.

### Labels

**Every feature is named on creation.** The prompt is part of finishing the
shape, not an optional extra: an unnamed zone is indistinguishable from the
zone beside it, and the label is what makes the drawing worth anything to
whoever receives it.

Labels are anchored at the **area-weighted centroid**, not the bounding-box
centre. They differ a lot for a real boundary — an L-shaped county puts its
bounding-box centre in the notch, outside itself, which would float the label
over the neighbouring county. A degenerate ring (three collinear points
enclose no area, and the formula divides by it) falls back to the bounding
centre. A line labels its midpoint, not its start, where the label would land
on whatever the route begins at.

Shapes get a floating label with no pin; a marker in the middle of a county
reads as a station, which is the confusion the separate palette already exists
to avoid.

### One map view for every basemap

Drawing and overlays need `MKMapView` — SwiftUI's `Map` can host neither a tile
overlay nor a vector one. So the MKMapView path now serves *all* basemaps
whenever there are overlays or drawing in play, not just the offline one.
Otherwise both would silently do nothing on Apple's basemaps, which is exactly
where an operator would first try them.

---

## 3a. Editing existing features

Marks the operator places go to a scratch layer ("My Marks"), created on first
use and kept **separate from imported layers**. Silently editing an agency's
boundary file and writing it back would be worse than refusing to — there would
be no way left to tell what was original.

Only features with `isUserPlaced` can be removed or renamed. Exported marks
carry an `axterm_placed` property, so a layer that round-trips through export
and import comes back editable rather than frozen.

---

## 4. Writing

`ShapefileWriter` emits all four files, because a `.shp` alone is not a
shapefile:

- `.shp` geometry
- `.shx` index — offset and length per record, in **16-bit words**
- `.dbf` attributes, dBASE III, fixed-width ASCII
- `.prj` the coordinate system

They go out zipped (`ZipWriter`, stored/uncompressed — about eighty lines,
cheaper than a dependency). Verified against the system `unzip`, not against
AXTerm's own reader: a self-consistent archive no other tool accepts is
worthless, since the point is handing it to somebody else's GIS.

### Winding

A shapefile polygon's outer ring must wind **clockwise** and its holes
**counter-clockwise**. Readers use the winding to tell them apart, so a ring
wound the wrong way becomes a hole — and the county disappears, leaving a
county-shaped gap.

### dBASE quirks

Field names are upper-case **ASCII**, capped at ten characters. ASCII
specifically: a dBASE III header has no encoding field, so a reader interprets
the bytes in whatever code page it assumes. `ÉVACUATION` is a different name to
every reader that opens it, and some reject the header outright. Values are
transliterated rather than dropped — an operator's note with an accent should
still be readable on the other end.

One geometry type per file: the format's own rule. Mixing is refused with an
explanation that points at GeoJSON, which allows it.

---

## 5. Sending over the air

This is where an operator can waste an afternoon, so the numbers are stated in
airtime rather than bytes.

A county boundary is tens of thousands of coordinates. As a zipped shapefile
that is a megabyte or more, which at the **~21 bytes/second this station has
actually measured on 145.050** is over thirteen hours, across dozens of
sessions. Twelve marked positions are a couple of kilobytes of GeoJSON and
cross in under a minute. Four orders of magnitude between them.

`MapOverlayExport.assess` runs the size through `WinlinkAirtimeEstimate` — the
same estimator the catalog uses, with the same measured-versus-assumed
provenance — and past forty minutes says plainly that this is not a reasonable
thing to put on a shared channel, and that a memory card will do it in seconds.

**GeoJSON is the format for the radio.** It is text, so LZHUF actually
compresses it; a zipped shapefile is already compressed and gains nothing. The
Winlink action offers GeoJSON only.

### The coordinate system is stated, always

`MapOverlayMessage` puts the CRS in the message **body**, not just in the
attachment. GeoJSON's specification mandates WGS 84, but the person opening it
in twenty minutes under pressure will not be reading RFC 7946 to confirm that —
and the statement survives the file being forwarded on.

- **GeoJSON** — no projection sidecar exists, so the body carries the full WKT.
  A recipient whose software wants a `.prj` can paste it and be certain. It
  also states that coordinates are `[longitude, latitude]`, which is the
  opposite of the shapefile convention.
- **Shapefile** — the `.prj` is in the archive and is authoritative, so the
  body points at it rather than repeating a WKT that could disagree.

A `crs` member is deliberately **not** written back into the GeoJSON: RFC 7946
removed it and fixed the coordinate system, so adding one produces something
that is no longer valid GeoJSON and that some parsers reject.

Mark positions also appear in the body in degrees-decimal-minutes — the format
the Winlink position templates use. The most important case, a handful of
marked locations, stays readable even if the attachment is stripped, truncated,
or opened on something with no mapping software at all. A long list is
truncated with a count of what was left out, so a short list is
distinguishable from a shortened one.

---

## 6. Tests

- `ShapefileReaderTests` — 14 cases, built from raw bytes rather than fixtures
  so the endianness and offsets are visible in the test itself.
- `ShapefileWriterTests` — round-trips through the reader, which is the only
  check that proves the bytes are right; plus index offsets pointing at real
  records, winding, the four component files, and the `.prj` the reader
  accepts.
- `DBFWriterTests` — field-name rules, fixed-width padding, transliteration,
  and a header whose declared counts match the file.
- `ZipWriterTests` — verified against the system `unzip`, plus the CRC-32 test
  vector.
