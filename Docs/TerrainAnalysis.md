# Terrain Analysis

Whether a signal can physically get from here to there, and why not when it
can't.

Measured link quality (`Docs/RoutingAndLinkQuality.md`) says *whether* a
gateway answers. This says *why* — and says it before the first transmission
rather than after twenty failed ones.

---

## 1. The two corrections that make it honest

A straight line drawn between two stations on a map is not a radio path.

**Earth curvature.** Two 10-metre antennas 100 km apart cannot see each other
over flat ground; the planet is in the way. The bulge is applied with the
standard **k = 4/3** effective-radius factor, which accounts for the
atmosphere refracting VHF slightly downward. It is zero at the ends and
greatest at mid-path — 147 m on a 100 km link — which is why an obstruction in
the middle matters most.

The familiar radio horizon `4.12 × √h` km falls out of the same factor, and is
asserted against the textbook value so the constant cannot drift.

**The Fresnel zone.** A path that clears the ground by a metre is not a clear
path. Radio needs an ellipsoidal volume around the line unobstructed, and
intruding into it costs signal well before anything physically blocks the way.
The threshold is **60% of the first Fresnel zone** — the long-standing
engineering rule, below which diffraction loss becomes significant.

### A finding worth stating plainly

At 145 MHz the first Fresnel zone at the middle of a 20 km path is **over 100
metres across**. Two 10-metre antennas over flat ground clear about **4%** of
it.

| Path | F1 at mid-path | Earth bulge | Clearance with 10 m antennas |
|---|---|---|---|
| 5 km | 50.8 m | 0.4 m | 19% of F1 |
| 10 km | 71.9 m | 1.5 m | 12% of F1 |
| 20 km | 101.7 m | 5.9 m | 4% of F1 |
| 50 km | 160.7 m | 36.8 m | **blocked** |

Geometrically those paths have line of sight. In practice they are
diffraction-limited — which is exactly the "answers but struggles" signature
that shows up in the link-quality data with no explanation attached. It is
also why gateways sit on hilltops.

`testLowAntennasOverFlatGroundAreMarginalEvenAtModestRange` pins this,
because it is counter-intuitive enough that somebody would otherwise "fix" it.

---

## 2. Verdicts

| Verdict | Meaning |
|---|---|
| **clear** | Line of sight, Fresnel zone ≥ 60% clear. Terrain is not the limit. |
| **marginal** | Line of sight, Fresnel zone intruded on. Expect retries and slow throughput — a terrain-limited path, not a broken one. |
| **obstructed** | Terrain above the line. No line of sight; a direct contact is unlikely regardless of power. |
| **unknown** | The elevation data has gaps. **No verdict is given.** |

Every verdict explains what to do about it, not merely what it is — a blocked
path names the digipeater option and the height that would clear it.

**The endpoints are excluded from the verdict.** The antennas sit on their own
ground, so clearance there is exactly the antenna height and the Fresnel radius
is zero. Including them would report every path as obstructed by its own mast.

**A gap produces no verdict.** The missing stretch is exactly where the ridge
might be, and reading a hole as sea level would turn an unknown mountain into a
clear path — the most dangerous available way to be wrong. `NaN` is the
no-data marker rather than zero or −9999, because every comparison against it
is false, so a gap cannot pass a clearance test.

---

## 3. Elevation data

**USGS 3DEP.** Public domain, no API key, no policy against retrieving a
region — the same terms as the USGS basemap already in use. US coverage only,
and that is stated rather than discovered.

Verified live: `epqs.nationalmap.gov` returns 4346.26 m for Mount Blue Sky at
1 m resolution, and the image service exports **float32 GeoTIFF** grids at an
arbitrary bounding box and size.

Grids are stored as raw float arrays in SQLite, one tile per square degree at
1024 samples a side — roughly 100 m per sample, finer than the ridges that
decide a VHF path, about 4 MB a tile. The TIFF wrapper is parsed once on
download and discarded; decoding an image inside a loop that runs a few
hundred times per profile would be absurd.

### The trap, found by testing against real data

3DEP returns **tiled** TIFFs, not stripped ones — and the tile is padded
beyond the requested image size. A 64×64 request arrives inside a 128×128
tile.

The first version of `GeoTIFFReader` handled strips only, and would have
failed outright on live data. Reading the buffer linearly instead would have
been worse: it produces a grid that is plausibly shaped and geometrically
wrong.

This was caught by fetching a real tile and inspecting its tags, not by a
synthetic fixture — a reader written against a hand-made stripped TIFF passes
its own tests and then skews live terrain.

`ImageIO` is deliberately not used: 32-bit float samples are not pixels, and
going through a `CGImage` would quantise elevations to whatever colour space
it picked.

---

## 4. Sampling

Points along the path are interpolated **spherically**, not linearly in
latitude and longitude. Over a 100 km path the two differ by hundreds of
metres, and a profile sampled along the wrong line is a profile of the wrong
ridge.

Elevation lookups are **bilinear** between grid samples. At ~100 m spacing,
nearest-neighbour puts visible steps in a profile and can miss a ridge crest by
half a sample. The interpolation is between real measurements, so it smooths
without inventing terrain — and refuses to interpolate across a no-data gap.

256 samples per path puts them about 400 m apart on a 100 km link. More cannot
help beyond the resolution of the data.

---

## 5. Tests

`TerrainProfileTests` — 19 cases, against synthetic terrain (a plain, a ridge,
a valley, terrain with a hole in it) so the **physics** is pinned rather than
whatever a download happened to contain. The physical claims are checked
against textbook values, not the implementation's own output: a path-profile
tool that is self-consistent and wrong is worse than none, because an operator
will trust it.

`GeoTIFFReaderTests` — 9 cases against a **real 3DEP response** committed as a
fixture (bbox −105,39 to −104,40). Expected values were derived by decoding it
independently and cross-checked against the world: south-west corner 2790 m
Front Range foothills, north-east corner 1444 m plains. All four corners are
asserted, which pins the orientation completely — a grid read upside down or
mirrored gives a profile of terrain that exists, somewhere else.

`ElevationStoreTests` — 13 cases: tile indexing floors rather than truncates
(`Int(-104.99)` is −104, which would read the wrong mountains), north row
first, west column first, bilinear interpolation, and no-data staying no-data
all the way through to the verdict.
