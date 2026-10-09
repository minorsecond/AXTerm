# Hazard Layers

Status: design, 2026-10-09. Not built yet. Branch `feature/hazard-layers`.

Hazard data for storm spotters and emergency communicators (SKYWARN, ARES,
RACES): watches and warnings, fires, storm reports, earthquakes, snow and
rain fields. AXTerm shows it on the station map and can share it over
Winlink, through the station's BBS, or straight over a packet session.

It builds on the map overlay system (`Docs/MapOverlays.md`), which already
reads shapefiles and GeoJSON, keeps layers as GeoJSON files, writes both
formats, and sends a layer as a Winlink attachment with an airtime estimate.
Nothing here replaces that; hazard data becomes another kind of layer.

---

## 1. The rule this is built around

Every source below is an internet feed, and the case AXTerm is built for is
the one where the internet goes away (`Docs/WeatherDataSources.md`). So:

- **Every point and polygon says where it came from and how old it is**:
  source, issued, expires, fetched, and, for anything that arrived over the
  radio, who relayed it and when.
- **The last good copy is kept.** With no connection the layer stays on the
  map, marked stale, its expiry still shown. An expired item fades; it does
  not vanish without a trace, and it never looks current.
- **Every hazard layer starts off.** Each one sends a request carrying the
  station's position, so each waits until the operator switches it on in
  the map's Layers sidebar (operator, 2026-10-09).
- **Nothing transmits on its own.** Sharing is something the operator does.
- **Our station never poses as the agency.** A relayed warning is signed as
  ours and carries the agency's own text and times. On 144.390, WXSVR already
  sends NWS bulletins, so AXTerm adds nothing there.

---

## 2. Sources

| Layer | Geometry | Source | Access | Notes |
|---|---|---|---|---|
| Watches, warnings, advisories | Polygons | NWS, `api.weather.gov/alerts/active` | Free, no key, User-Agent required | Storm-based warnings carry their own polygon. Zone-based ones (Red Flag, Winter Storm, Wind) list affected zones; zone outlines are fetched once from `/zones` and cached. Drawn in NWS's standard hazard colors |
| Fire perimeters | Polygons | NIFC WFIGS current perimeters | Free, ArcGIS feature service | Refreshed about every 5 minutes. Perimeters drop off on NIFC's schedule and are not ground truth |
| Fire incidents | Points | NIFC WFIGS incident locations | Free | Name, acres, containment |
| Fire hotspots | Points | NASA FIRMS (VIIRS, MODIS) | Free key | Often ahead of official perimeters |
| Storm reports (snow, hail, wind damage, flooding, tornado) | Points | NWS Local Storm Reports via Iowa Environmental Mesonet, `geojson/lsr.geojson` | Free | Snow reports carry measured or estimated amounts. IEM is a university service; labeled unofficial |
| mPING | Points | mPING API (University of Oklahoma, NSSL) | Token | The general license gives the last 4 hours; some report types are NWS only |
| Severe outlook | Polygons | NOAA SPC convective outlooks | Free | Marginal through High |
| Earthquakes | Points | USGS GeoJSON summary feeds | Free | |
| Snow depth, snowfall | Grid | NOAA NOHRSC | Free | Shared as contours or a small grid, §6 |
| Rain totals | Grid | NWS QPE | Free | Same |
| Space weather | Values | NOAA SWPC | Free | Already in AXTerm (`SolarConditions.swift`) |

Watch Duty has no public API; its data page sells team plans. Most of what it
shows comes from NIFC perimeters and NOAA/NASA satellite hotspots, which are
above.

**County centers, built in.** `Resources/us-county-centers.csv` lists every
US county's Census code, center, area, state and name (3,222 counties, 147 KB), reduced
from the US Census Bureau's 2024 Gazetteer counties file, which is public
domain. NWS alerts name their counties by SAME code, so "Within N miles"
rules out an alert whose counties are all far away before fetching any zone
outline (`CountyCenters`). A county counts as near when its center, less
half again its own radius, is within the distance: a county's edge can be
much nearer than its center, and a miss would hide a warning.

**Choosing the area.** The NWS layer fetches for where the station is,
within a distance of it, or for ticked states or counties. Nothing is typed.
Switching to States ticks the station's own state; switching to Counties
ticks its county, and the list leads with the nearest 25 counties, with a
search for the rest. Counties are fetched as their states and kept when an
alert names one of them by SAME code, so an alert issued by forecast zone is
not missed. Close in, the list says "Nearby" instead of a distance, since a
county's edge is estimated from a circle of its area.

**Not getting throttled.** At most 25 new zone outlines per refresh, 0.2 s
apart. HTTP 429 or 503 pauses all fetching: the server's Retry-After when it
gives one, else two minutes doubling to thirty, reset by a success.

Keys (FIRMS, mPING, AirNow if added) go in the Keychain, like the Winlink CMS
key. A layer that needs a key stays out of the list until one is entered.

The NWS asks callers to identify themselves. AXTerm sends its name and the
project's GitHub address, never the operator's email.

---

## 3. Model

One feature type for every source, so the map, the list, the car card and
the sharing code see one thing:

- geometry: point, line, polygon (holes kept) or multi-part
- kind: warning, watch, advisory, fire perimeter, hotspot, storm report, …
- event text and severity as the source gives them
- times: issued, effective, expires, fetched
- provenance: source name, source ID, and a relay chain (station, path, time)
  for anything received over the radio
- the source's own fields, all of them, kept as properties even when the UI
  shows a few

Each source stores everything it returns. What the UI shows is a filter over
that, so a later screen can use a field without a new fetch.

---

## 4. Live layers

- Each source is a read-only layer that refreshes on its own schedule (NWS
  every minute or two, NIFC and storm reports every five, using conditional
  requests where the server supports them).
- Filtered to an area of interest: GPS when "This device's location" is on,
  otherwise the station's grid, with a radius the operator sets.
- Layers appear in the map's Layers sidebar like any other, each with a
  tooltip that says what it is, where it comes from and when it was fetched.
- **Inside it.** When the station's position falls inside a warning polygon
  or a fire perimeter, the map says so, and car mode's card puts it first:
  "Inside: Red Flag Warning until 8:00 pm".
- **Save as layer** freezes a live layer into an ordinary overlay at that
  moment. That is what gets shared, so the recipient sees exactly what the
  sender saw.

---

## 5. Sharing

One file, three paths. GeoJSON for the radio: it is text, so Winlink's LZHUF
and AXDP's compression shrink it well. Shapefile export stays for GIS users.
KML import and export is added because CalTopo and Google Earth are common in
search and rescue and emergency management.

| Path | Today | Added |
|---|---|---|
| Winlink | A layer goes out as a GeoJSON attachment (`MapOverlayMessage`) | On receipt, "Add to map" |
| BBS | File areas and downloads | A MAPS area on the station's BBS. With internet the station keeps it current from the feeds: warnings for the county, active fires, today's storm reports |
| Packet session | AXDP file transfer | On receipt of a map file, "Add to map" |
| APRS | Objects | Points only (a spotter report, a fire's location). Polygons are too long for APRS |

**Provenance travels inside the features**, not only in the message body, so
a forwarded file still says "NWS, issued 2:14 pm, expires 6:00 pm, relayed by
K0EPI-2 at 3:04 pm". Property names are plain (`source`, `issued`,
`expires`, `relayedBy`); they are data, not AXTerm display settings, which
stay in the `.display.json` sidecar as today.

**The same file twice is one layer.** A file that arrives by both BBS and
Winlink is recognized by a hash of its features and merges rather than
doubling.

**Size tools before sending**, with the airtime estimate
(`MapOverlayExport.assess`) updating as they change:

- clip to an area: a drawn box, a radius, or a county
- simplify outlines to a tolerance in meters (Douglas-Peucker)
- round coordinates (4 decimals is about 11 m, 5 about 1 m)
- drop attributes nobody needs

For scale: one NWS warning polygon is a few hundred bytes, seconds on a 1200
baud link. A raw fire perimeter can run to tens of kilobytes; simplified to
about 100 points it is around a minute.

---

## 6. Grids

Gridded fields (snow depth, snowfall, rain totals, a radar snapshot) are
shared three ways, smallest first:

1. **Contours.** A snowfall grid becomes the 2, 4, 6 and 12 inch lines: a few
   kilobytes of vectors that draw cleanly and read at a glance. Usually the
   right trade for the radio.
2. **ESRI ASCII grid** (`.asc` with a `.prj`) when the receiver needs values.
   Text, compresses well, and QGIS and ArcGIS open it directly. A county at
   about 1 km, rounded to whole inches, compresses to a couple of kilobytes.
3. **PNG with a world file** for imagery such as a clipped radar snapshot:
   10 to 30 KB, several minutes on the air, so the estimate decides.

Every grid is clipped to the area of interest first and carries its units,
legend and valid time.

---

## 7. Spotter reports

Everything above needs somebody with internet. Spotter observations do not.

A spotter marks a report on the map ("Hail 1.00 in", "Snow 12 in, measured",
"Tree down, road blocked"). AXTerm sends it as a map point, an APRS object for
nearby stations, and a Winlink form for net control. Net control's map fills
with field reports over RF alone.

---

## 8. History

The live layers hold the latest copy; history holds everything. Every
distinct hazard fetched or received is kept, append-only, in the station's
database:

- **One row per version.** An NWS update or cancellation references the
  message it replaces, so the chain is kept and the latest version is the
  live one. A fire perimeter gets a new row only when its shape changes
  (compared by a hash of its geometry). Storm reports and quakes are one row
  each.
- **Provenance with every row**: source, issued, expires, fetched, and the
  relay chain for anything that arrived over the radio.
- **What it is for:**
  - a time slider on the map: what was in effect at 3:40 pm;
  - an after-action export of a time window as GeoJSON or CSV, for an ARES
    or SKYWARN debrief;
  - spotter reports read against the warnings in effect when they were made.
- **Size.** An NWS alert with its polygon is a few kilobytes; a busy day in
  Colorado is well under a megabyte. Fire perimeters are larger and change
  often, so they are kept when their shape changes rather than on every
  fetch. Grids are kept only when saved or shared, not on every refresh.
- **Retention** is the operator's setting, kept by default since the data is
  small.

## 9. Order of work

1. Live layers: NWS warnings (polygons and zones), NIFC perimeters and
   incidents, storm reports, earthquakes; provenance, staleness, the "inside"
   line in car mode. No keys needed. History (§8) is recorded from the
   start, so nothing fetched before the time slider exists is lost.
2. Sharing: "Add to map" on receipt (Winlink, BBS, packet session), the BBS
   MAPS area, the size tools, KML.
3. Grids: contours, then ASCII grids, then imagery.
4. Spotter reports. Could move earlier, since it is the part that works with
   the internet down.
5. Keyed sources: FIRMS, mPING, then SPC outlooks.

Each step is built test first, and a change to what goes on the air waits for
the operator's approval.

## 10. Open questions

- The NIFC service URLs need checking against the NIFC open data site before
  step 1; mirrors disagree.
- Refresh limits and caching rules for each source, read from their own terms.
- How a received layer that has expired is shown: faded on the map, or kept
  only in the list.
- Whether the BBS MAPS area is public to callers or limited to the sysop's
  list during an activation.
