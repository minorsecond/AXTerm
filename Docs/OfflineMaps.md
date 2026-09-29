# Offline Maps

A basemap stored on the device, so the map works with the network down —
which is the situation this app exists for.

---

## 1. What was there before, and why it was not enough

`OfflineMapSnapshot` captures one PNG of one region at one zoom via
`MKMapSnapshotter`. That is a photograph of a map, not a map: it cannot be
panned past its edge or zoomed past its scale. Those are exactly the two
things an operator does when working out whether a hill is in the way.

It is still there and still useful as a quick "save what I'm looking at". The
tile store below is the real answer.

---

## 2. The tile store

`MapTileStore` — SQLite, **MBTiles 1.3 schema verbatim**.

The schema is not merely inspired by MBTiles; it *is* MBTiles. That means:

- a region downloaded here can be read by any other tool
- an `.mbtiles` file the operator obtained anywhere can be imported and used
  directly

The second is the important one. It is the path that is unambiguously allowed
by every provider's terms, and the only one that scales to a whole state.

### The bug this schema invites

MBTiles stores rows **bottom-up (TMS)**; MapKit asks **top-down (XYZ)**.
`MapTileStore.tmsRow(y:zoom:)` converts, and `store`/`tile`/`rows` all apply
it consistently.

Getting this backwards produces a map that looks entirely plausible — tiles
render, at the right zoom, in the right places — but is mirrored north to
south. On a bearing-and-range tool that is not cosmetic: it puts the ridge on
the wrong side of the operator. `testTMSConversionRoundTripsAndActuallyFlips`
asserts both that the conversion round-trips *and* that it is not the
identity.

---

## 3. Sources and their terms

`MapTileSource` encodes each provider's usage policy as data, because the
policy constrains what the app may do.

| Source | Bulk download | Why |
|---|---|---|
| **USGS Topo** | **allowed** | US federal government work: public domain, no API key, no policy against retrieving a region. The 7.5-minute topo series, which is also the *right* map here — it shows the ridge between two stations. Max zoom **16**. |
| **USGS Imagery + Topo** | **allowed** | Aerial imagery with topo lines over it. Max zoom **16**. |
| **USGS Shaded Relief** | **allowed** | Terrain shading only. Coarse (max zoom **13**) but tiny, so a whole state costs very little — good as a wide layer under a smaller detailed download. |
| **Imported file** | allowed | No server to abuse. |
| **OpenTopoMap** | **refused** | Runs on donated hardware and asks that tiles not be bulk-downloaded. Browsable, and browsed tiles are cached. |
| **OpenStreetMap** | **refused** | The OSMF tile usage policy forbids bulk downloading from their servers. Browsable, and browsed tiles are cached. |

The zoom limits are **verified against the live service**, not taken from its
metadata: `USGSTopo/MapServer?f=json` advertises levels 0–23 while the tile
endpoint returns 404 above 16. Trusting the metadata would have produced a
download that reports thousands of failures at the top of its range.

ArcGIS orders its tile path **row before column** — `{z}/{y}/{x}`, not
`{z}/{x}/{y}`. Getting that backwards returns tiles from entirely the wrong
place: plausible-looking terrain, hundreds of miles away, with no error.

`OfflineRegionDownloader.download` refuses a source whose
`permitsBulkDownload` is false **before making a single request**, and surfaces
the provider's own wording. An app that quietly pulled 50,000 tiles from a
volunteer-run server would be abusing it and would get the operator's address
blocked.

What *is* permitted, and is done: **caching tiles the operator actually
browses**. `OfflineTileOverlay` writes every fetched tile back to the store,
so a source that forbids bulk download still ends up usable offline for the
area actually worked.

Attribution is required by the licence and is drawn on every map that uses
these tiles. Offline tiles are still someone's work.

---

## 4. Rendering

`OfflineTileOverlay: MKTileOverlay` with **`canReplaceMapContent = true`**.

That flag is what makes this a real offline map: MapKit stops drawing its own
basemap underneath. Without it, MapKit reaches for Apple's servers for the
base layer and the map is blank in the field no matter how many tiles were
downloaded.

SwiftUI's `Map` cannot host a tile overlay, so the offline basemap is drawn by
`OfflineBasemapMapView` — an `MKMapView` representable. The other basemaps
keep using SwiftUI's `Map`, where it is the better tool. Markers come from the
same `StationScope` model either way, so a hollow marker still means "a lead,
not a fix" offline.

A missing tile reports `nil`, not an error: MapKit draws an empty square,
which reads as "no data here" — the truth — rather than raising an alert the
operator can do nothing about.

---

## 5. Downloading a region

- **Estimate first.** `OfflineRegionDownloader.estimate` reports tile count
  and approximate size *before* committing. Each extra zoom level roughly
  quadruples the count, and a test pins that ratio because the estimate
  depends on it.
- **Coarse zooms first.** An interrupted download leaves a blurry map of the
  whole area rather than a sharp patch and nothing around it.
- **Skip what is stored.** A resumed download does not re-fetch; the
  operator's connection is usually the scarce resource.
- **Four concurrent requests.** The difference between four and forty is
  nothing to the operator and a great deal to the provider.
- **Confirm above 20,000 tiles.** An operator cannot see a tile count and know
  what it means.
- **Stopping keeps what landed.** A partial download is a partial map, not a
  wasted one.

---

## 6. Importing a file

### Raster only, and it says so

MapKit renders raster tiles. A **vector** `.mbtiles` (format `pbf` or `mvt`)
holds compressed geometry, and importing one would fill the store with tiles
that draw nothing — an offline map that looks stored and is blank in the
field, which is the worst possible outcome. The import reads the `format`
metadata and refuses with an explanation instead.

### Where raster .mbtiles come from

Pre-made raster files are less common than vector ones, so in practice:

- **Download a USGS region from inside AXTerm.** For US operating this is the
  simplest path and needs nothing else.
- **Generate one** from any XYZ source you are entitled to use, with
  `mbutil`, `tilemaker`, QGIS's QMetaTiles plugin, or `gdal2tiles` +
  `mb-util`.
- **OpenAndroMaps / OpenTopoMap** publish offline map files; check the format
  is raster before importing.

Anything advertised as "vector tiles", "PMTiles" or "OpenMapTiles" is vector
and will be refused.

### Copying, not referencing

The import **copies** rather than referencing the file. The operator picked it
out of Files or a Downloads folder: on iOS that URL is a security-scoped loan
that expires, and on macOS the volume may be ejected. Copying makes the map
keep working after the source disappears, which is the entire point.

Copying streams zoom level by zoom level (`forEachTile(atZoom:)`) so a
multi-gigabyte file is never loaded into memory.

---

## 7. UI

`OfflineMapsView`, reachable from the toolbar of both map surfaces on both
platforms. The source picker separates **"Can be downloaded"** from **"Browse
only"** and defaults to USGS Topo, so the operator does not have to discover
by trial which sources refuse.

The "Offline" basemap appears in `MapBasemapPicker` only when tiles are
actually stored. Offering it empty produces a blank map that reads as a bug
rather than as an empty cupboard.

---

## 8. Tests

`AXTermTests/Unit/Station/MapTileStoreTests.swift` — 20 cases.

Tile maths: zoom 0 is one tile; the origin lands in the expected quadrant; x
runs east and y runs **south**; polar coordinates clamp inside the grid; a
region's tile list contains its own corners; each zoom level quadruples the
count; coarse levels come first.

Store: tiles read back at the same coordinates; TMS round-trips *and* flips;
re-storing replaces rather than duplicates; statistics match what is stored;
deleting frees the space; streaming a zoom level returns every tile exactly
once; metadata round-trips.

Sources and policy: every source declares its terms; a source that refuses
bulk download says why; the community tile servers are asserted to refuse;
imported files are always allowed; URL templates leave no placeholder
unfilled; subdomain choice is stable so caches hit.

Downloader: a forbidden source is refused with the provider's own reason
before any request; downloading from a file source fails with an explanation;
the estimate flags large regions; concurrency stays polite.

---

## 9. Overlay layers: shapefiles and GeoJSON

The basemap answers "what is the terrain here". Overlays answer "what are the
boundaries that matter to this activation" — county lines, ARES districts,
evacuation zones, flood polygons, repeater coverage.

Agencies distribute these as **shapefiles**. An operator handed a `.zip` from
an EOC has a shapefile, not GeoJSON, and telling them to convert it first is
telling them to find a computer with GDAL on it during an activation. So
`ShapefileReader` reads the format directly: points, polylines and polygons,
including the Z and M variants (a boundary with elevations is still a
boundary). GeoJSON goes through MapKit's own `MKGeoJSONDecoder` and converts
into the same geometry model, so the rest of the app draws one representation
rather than two.

### The two traps

**Coordinate order.** In a shapefile, x is longitude and y is latitude, in
that order. Swapping them puts a Colorado county off the coast of Somalia —
and produces no error at all.

**Projection.** A shapefile carries no coordinate system in the `.shp`; the
numbers are just numbers. If the companion `.prj` says State Plane feet and
you read them as degrees, every feature lands thousands of miles away,
silently. So the `.prj` is read and checked: geographic WGS 84 or NAD 83 is
accepted, a projected system is refused by name, and a missing `.prj` is
accepted because most agency downloads have none and are lat/lon.

### Other decisions

- **A truncated record stops the read.** A partially-drawn evacuation
  boundary is indistinguishable from a complete one, and somebody may plan
  around it.
- **Unsupported geometry is named, not skipped.** A boundary that quietly
  fails to draw is worse than one that refuses to.
- **Null shapes are skipped** — a legal record meaning "no geometry here".
- **Polygon holes are kept.** Dropping them draws a solid county over a lake.
- **The palette avoids green/yellow/orange**, which the station markers use
  for link quality. A boundary sharing that colour invites reading it as a
  measurement.
- **Overlays are device-local and not synced.** An overlay is a working file
  for one activation, often large; pushing a county shapefile through the
  mailbox's sync channel would cost a lot for no gain.

### Tests

`AXTermTests/Unit/Station/ShapefileReaderTests.swift` — 14 cases, built from
raw bytes rather than fixtures so the endianness and offsets are visible in
the test. A shapefile mixes big- and little-endian in a single record, and its
record lengths are in 16-bit words — the detail that has broken every naive
shapefile reader ever written.
