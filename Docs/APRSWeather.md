# APRS Weather

A weather station is an ordinary APRS station whose symbol code is `_`. Its
readings ride in the same beacons as its position, in fixed-width single-letter
fields. AXTerm decodes them, keeps the latest reading against the station, and
shows it in two places: the whole reading on the station's card, one number on
the map.

## Wire format (`AXTerm/APRS/APRSWeather.swift`)

Pure parser, golden-tested (`APRSWeatherTests`). Two shapes carry weather, and
they differ in one place that matters, so the caller says which it has rather
than letting the parser guess.

**With a position** — a normal position report whose symbol code is `_`:

```
!3959.13N/10515.42W_220/004g009t047r000p000P000h63b10132wRSW
                   │└─┬─┘ └┬┘ └┬┘ └┬┘        └┬┘  └─┬─┘└─┬─┘
                   │  │    │   │   │          │     │    └ comment
                   │  │    │   │   │          │     └ pressure, tenths of mb
                   │  │    │   │   │          └ humidity %
                   │  │    │   │   └ rain: hour / 24 h / since midnight
                   │  │    │   └ temperature °F
                   │  │    └ gust mph
                   │  └ wind direction° / sustained mph
                   └ symbol code `_`
```

**Positionless** (`APRSParser.parseWeather`) — DTI `_`, an 8-character MDHM
timestamp, then the same fields with wind as `c` (direction) and `s` (speed).
Many home stations beacon a bare position on one interval and a positionless
report on another.

Three details the format hides:

- **Wind sits in the course/speed slot.** For every other station `220/004` is
  course and speed. Decoding a weather station that way reports a house
  travelling at four knots, and puts a fixed station in the map's *moving*
  class. `APRSParser` therefore routes the whole tail to the weather parser
  when the symbol code is `_`, and leaves `courseDegrees`/`speedKnots` nil.
- **`s` means two things.** Snowfall in a position report, wind speed in a
  positionless one. Hence `APRSWeather.Form`.
- **Missing is not zero.** A station with no anemometer sends dots or spaces,
  so every field is an `Int?` and a reading with nothing in it parses to nil
  rather than to an all-zero reading. `0 mph` is claimed only when a station
  with an anemometer reports calm.

Units stay as transmitted (°F, mph, hundredths of an inch, tenths of a
millibar) so the parse is lossless. Conversion happens at display time, keyed
by the same imperial/metric preference the map already uses for distances.

`h00` is 100% humidity — two digits have no room for three. Temperatures below
zero ride as `-01`…`-99` inside the same three characters.

Not handled: Mic-E weather (a separate encoding), and the raw rain counter
`#` (a tick count, not a depth — parsed past, not stored).

## Keeping the reading (`Station`, `StationTracker.applyAPRS`)

`Station.weather` and `Station.weatherHeard` are held **apart from**
`Station.aprs`. They are separate observations: a station that beacons its fix
and its sensors on different intervals would otherwise lose its reading every
time a bare position arrived. A positionless report updates the weather and
leaves the position alone; a position report with no weather leaves the
reading and its timestamp alone.

A positionless report never becomes an `APRSReport` — that type promises
coordinates, and this shape has none.

## Showing it

**The card and the tooltip** (`HeardStationMap.weatherLines`) get the whole
reading, one short line per group, each naming its units:

```
47°F · humidity 63% · 1013.2 mb
Wind 4 mph from SW, gusting 9 mph
Rain 0.12 in today
```

Only what the station actually sent appears. A reading older than an hour
(`HeardStationMap.weatherFreshWindow`) gains a `Reading taken …` line: weather
is the one thing on this map that goes stale invisibly, because a temperature
from this morning looks exactly like a temperature from a minute ago.

**The map** (`HeardStationMap.weatherBadge` → `StationScope.Site.weatherBadge`)
gets one value: the temperature, drawn after the callsign in the same label.
Everything else needs its units spelled out to mean anything, and a marker has
no room to spell anything out. A reading past the freshness window is **not**
badged at all — a stale number on a map reads as the current one, and there is
nowhere on a marker to say otherwise. The card still carries it, with its age.

The badge is formatted in the model, not in the views: both renderers (SwiftUI
`Map` and the MapKit path) read the same `Site`, and neither should be
converting units. It is carried on the `Site` rather than in a side table so a
SwiftUI annotation actually rebuilds when a new reading arrives, and it is part
of the MapKit annotation's redraw comparison for the same reason.

The badge never touches `Site.label`. The label is the station's identity and
is used for the card headline and the action buttons; a temperature appended to
it would leak into all of them.

## Tests

- `AXTermTests/Unit/APRS/APRSWeatherTests.swift` — the wire format: complete
  and partial reports, filler, negative temperature, humidity wrap, calm wind,
  positionless reports, the comment tail, and the guard that wind is never
  reported as course and speed.
- `AXTermTests/Unit/Station/HeardStationWeatherTests.swift` — the reading
  surviving a position beacon that carries none, the card lines, the staleness
  rule, and the badge reaching the marker without contaminating the callsign.

## Pressure tendency — the area nowcast

`APRSPressureNowcast` turns the per-station tendencies in `APRSWeatherTrend`
into one statement about the channel. It is the only genuinely predictive
product RF carries: radar, lightning and warnings are all the internet, while
barometric pressure arrives in every APRS weather report as `bnnnnn`.

**Why tendency and not pressure.** Absolute pressure falls about 1 mb per 8 m
of altitude, and this channel's stations run from roughly 1500 m to over
3000 m — a spread of ~180 mb. APRS 1.01 says the field is reduced to sea
level, but plenty of stations are misconfigured or do not reduce at all, so an
absolute-pressure field would largely map who has set their WX3in1 up
correctly. Whatever offset a station carries, it carries in both readings and
it subtracts out of the change. That is what makes a tendency built from
strangers' weather stations worth trusting, and it is pinned by
`testAConstantPerStationOffsetCannotAffectTheVerdict`.

**What it refuses to claim.**

| guard | value | why |
|---|---|---|
| minimum span | 45 min | jitter over a short elapsed time divides into a dramatic rate |
| reading freshness | 1 h | a forecast from a dead station is the worst thing this app could print |
| window | 3 h | the standard every published interpretation is written against |
| stations for an area | 3 | one barometer is a station reading, two that disagree are nothing |
| agreement for an area | 0.7 | four falling is a system; three falling and three rising is noise |

Below the last two the nowcast is still produced — a steep fall next door is
worth seeing — but `isAreaWide` is false and the caveat says which.

**The middle station, not the average.** A barometer stuck at a wild rate is
the commonest failure on a channel of amateur weather stations, and a mean
lets one of them invert the verdict. A station inside the steady band counts
towards neither direction, so a quiet day cannot read as a confident system.

Thresholds are the standard synoptic ones, in `APRSWeatherTrend.Outlook`:
±1.0 mb/3h for falling/rising, ±3.5 for rapid.
