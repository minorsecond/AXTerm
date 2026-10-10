# Outdoor features: plan

Features for hiking, camping, SOTA and POTA, mostly for the iPhone and iPad on
the TNC4 and ID-50, some for the Mac. Agreed 2026-10-10 as a plan for later;
nothing here is built yet. Each item says what it is, where it runs, what it
builds on, and what needs a decision before work starts.

Anything that changes what goes out on the air needs the operator's approval
before it is built (CLAUDE.md, AXTERM-TRANSMISSION-SPEC.md). Those items are
marked **TX**.

## What already exists

Offline basemaps and terrain downloads (`Docs/OfflineMaps.md`), terrain path
analysis (`Docs/TerrainAnalysis.md`), coverage estimates, NWS hazard layers
(`Docs/HazardLayers.md`), car mode, APRS objects (`Docs/APRSObjects.md`),
APRS messaging, digipeat-echo detection (we know when a digi repeats us), the
Winlink POTA/SOTA activation form, and grid squares throughout.

## 1. Smart beaconing (TX)

Beacon by movement instead of a fixed interval: often when moving fast or
turning, rarely when stopped.

- **Where:** iPhone and iPad first, since they move; the Mac only matters for
  a laptop in a car.
- **Builds on:** the per-radio beacon (`RadioProfile.beacon`) and the position
  source the beacon already uses.
- **Rules:** the usual SmartBeaconing parameters: a slow rate and a fast rate,
  the speeds they apply at, a turn threshold that tightens with speed, and a
  minimum time between turn beacons. A stopped station falls back to the slow
  rate.
- **Tests:** a pure scheduler fed a recorded track (walking, driving, a
  switchback trail, stopped at camp) that asserts when beacons fire.
- **Decide first:** default parameters for walking versus driving, and whether
  it is per radio or per device.

## 2. "Was I heard?" on the Lock Screen

A Live Activity and widget: your last beacon, the digi that repeated it and
how long ago ("Repeated by W0NED, 3 min ago"), and the TNC4 and phone battery.

- **Where:** iPhone (Lock Screen, Dynamic Island), iPad widget.
- **Builds on:** `ConsoleLine.repeatAttribution` and digipeat-echo detection,
  which already know when our frame comes back; the TNC4 battery reading.
- **Work:** an ActivityKit target, a small shared model the app updates, and
  rules for when the activity starts and ends (radio connected, beaconing on).
- **Tests:** the model that turns heard echoes into the activity's state.
- **Decide first:** whether it shows only APRS beacons or connected-mode
  activity too.

## 3. Summit and park awareness

Bundle the SOTA summit list and POTA park list for offline use.

- Nearest summit or park with distance and bearing, on the map and in a
  compact card.
- Whether you are inside SOTA's activation zone (within 25 m vertically of the
  summit), from the offline elevation tiles.
- One tap puts "SOTA W0C/FR-063" or "POTA K-1234" in the beacon comment or
  status. **TX** only in that it changes beacon text the operator approves.
- Pre-fills the existing Winlink activation form.
- **Where:** iPhone and iPad; the Mac for planning.
- **Builds on:** the offline elevation tiles, the map overlays, the activation
  form.
- **Tests:** nearest-feature lookup, the activation-zone test against known
  summits, the comment text.
- **Decide first:** where the lists come from and how they are refreshed
  (licensing and update cadence for each source), and how large the bundle can
  be.

## 4. Coverage from here

Which digipeaters and iGates you can probably reach from a campsite or
summit, and the nearby high point that reaches more of them.

- **Where:** iPad and Mac for planning before a trip; iPhone in the field.
- **Builds on:** terrain analysis (Fresnel clearance, earth bulge), coverage
  estimates, and stations heard with known positions.
- **Work:** run the path check from a chosen point to every known digi and
  iGate; search a small grid around the point for the best spot; show the
  result on the map with reasons ("blocked by the ridge 2 km east").
- **Tests:** the search on a synthetic terrain grid; the ranking.
- **Decide first:** how far out to search and how to show uncertainty, since
  this is a prediction, not a measurement.

## 5. A home station that watches your mobile

A (705) watches for K0EPI-3. If it has not been heard for N hours, or moves
outside an area, A notifies you or a contact you choose.

- **Where:** the Mac at home, watching; notifications go to the phone, an
  APRS message, or email through Winlink. **TX** if it sends anything on the
  air.
- **Builds on:** stations heard, positions, notifications, APRS messaging.
- **Tests:** the watch rules over a recorded day of beacons, including gaps
  that should and should not alarm.
- **Decide first:** who gets told and how, and what counts as "not heard"
  when the hiker is simply out of range of every digi.

## Also planned

- **Track log and GPX.** Record your own track and others' tracks offline;
  export GPX; a "back to the trailhead" line. iPhone and iPad record, Mac
  reviews.
- **Group tracking with a compass.** A buddy list of callsigns on the map, and
  a compass view using the phone's heading that points at a person or at an
  APRS object you placed (camp, trailhead, meeting point).
- **Off-grid messaging gateways (TX).** Quick sends to SMSGTE (text messages),
  EMAIL-2 (email) and APRS2SOTA (SOTA self-spotting). Confirm each gateway's
  current message format before building, and check whether POTA has an
  equivalent.
- **Weather on the trail.** Cache the NWS point forecast and alerts for the
  trip area before leaving coverage; show nearby APRS weather stations; keep
  hazard alerts notifying in the background.
- **Battery-aware trail mode (TX).** One switch for a longer beacon interval,
  less GPS, and a dimmer display, with an estimate of hours left for the phone
  and the TNC4 at the current rate.
- **Emergency mode (TX).** The APRS emergency status and a higher beacon rate,
  behind a deliberate confirmation that cannot be triggered by accident.
- **Mac as planning and review station.** Download offline regions and
  terrain along a route and send them to the iPad; afterward, replay the
  trip's track and packets on the map.

## Suggested order

1, 2 and 3 first: each is fairly self-contained and matches how the phone is
already used on the trail. 4 and 5 next. The rest as wanted.
