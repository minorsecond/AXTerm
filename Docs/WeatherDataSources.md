# Weather Data Sources — what the radio actually carries

Written for the grid-down case: internet gone, cell gone, no forecast service,
AXTerm and a VHF radio still working. That case decides what is worth building,
because it removes every source that is really an internet feed wearing an
APRS costume.

## Available over RF, today

| Reading | Source | Status |
|---|---|---|
| Temperature | WX station beacons (`_` symbol) | Parsed, mapped, interpolated |
| Barometric pressure | same | Parsed, mapped, **3-hour tendency** |
| Humidity | same | Parsed, mapped, interpolated |
| Wind direction / speed / gust | same | Parsed, on the card |
| Rainfall 1 h / 24 h / since midnight | same | Parsed, on the card — **not** interpolated |
| Snowfall | same | Parsed, on the card |
| Station elevation | terrain store | Used to detrend temperature |

These survive a grid-down scenario because they are transmitted by local
stations on RF and relayed by local digipeaters. Nothing upstream is needed.

## Not available over RF, and why

**Lightning.** APRS has no lightning field. Lightning maps come from
time-of-arrival networks (Blitzortung, NLDN) whose whole method is combining
receivers over the internet — the thing that is gone. A handful of amateur
detectors beacon as APRS *objects* with free-text comments, which is a
different and much weaker thing: one detector's bearing and range estimate,
not a located strike. **What is actually achievable:** treat operator-placed
lightning objects as reports on the map, clearly marked as one station's
observation. Do not draw a strike map.

**Fire.** No sensor reports fire over APRS. Fire information arrives as either
NWS/incident bulletins relayed by an internet gateway, or as an operator
placing an object where they can see one. The second is real, useful, and
survives the grid; the first does not. **What is achievable:** operator-placed
objects and bulletins, attributed to whoever sent them.

**NWS watches and warnings.** Distributed on APRS by `WXSVR` as addressed
bulletins with zone codes. Genuinely valuable, and genuinely internet-fed: the
feed stops when the gateway's link does. Worth parsing, worth labelling with
its source so nobody trusts a warning that stopped updating six hours ago.

**Radar, satellite, model output.** All internet. Out of scope for RF.

## The honest shape of a grid-down weather picture

What a VHF receiver can actually give you is a **surface station network**:
a few to a few dozen points reporting temperature, pressure, wind, humidity
and rain. That is the same dataset surface analysis was built on for a
century, and it supports exactly what it supported then —

- **Pressure and its tendency.** The single most actionable thing here. A
  barometer falling four millibars in three hours says a system is arriving,
  and it says it with no model, no service and no internet. See
  `APRSWeatherTrend`.
- **Gradients** of temperature and pressure across the network, which show
  where a front is and roughly which way it is moving.
- **Wind** as reported, which confirms the above.
- **Rain where it was measured**, as numbers, not as a surface.

What it cannot give is anything convective and small-scale — individual
storms, hail, tornado tracks, lightning — because the network is too sparse in
space and time to resolve them, whatever is done with the numbers.

## Built

1. **Objects and items** (`;` and `)`) — fire, hazards, road closures,
   shelters, incident markers. Pure RF. See `Docs/APRSObjects.md`.
2. **NWS bulletins** (`WXSVR`), labelled with last-heard time and their
   internet origin so a stale warning cannot pass for a current one.
3. **Telemetry** (`T#` with `PARM`/`UNIT`/`EQNS`) — river gauges, solar,
   battery banks. Uncalibrated counts are shown as counts.
4. **Barometric tendency** from stored per-station history — the one thing a
   lone surface station can say about weather that has not arrived yet.

## Still open

1. **A station-plot marker** — the traditional surface-observation symbol with
   a wind barb, so a glance at the map reads as a weather chart.
2. **Trend history on more than pressure**, now that the history exists.
3. **Placing objects from AXTerm**, not only receiving them. Reporting a hazard
   is half the job and this app currently only listens.

See `Docs/APRSWeather.md` for the wire format and `Docs/APRSWeatherField.md`
for the interpolation and its limits.
