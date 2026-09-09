# Inferred Weather Field

A temperature wash over the map, interpolated from the weather stations this
receiver has actually heard. `AXTerm/APRS/APRSWeatherField.swift` for the
model, `AXTerm/UI/WeatherFieldOverlay.swift` for the raster.

It is an **inference from a handful of points**, and everything about it is
built so it cannot pass for an observation.

## Why not kriging

Kriging is the statistically optimal interpolator when you can estimate a
variogram, and estimating one takes on the order of a hundred observations;
thirty is the usual floor. A VHF receiver hears somewhere between one and a
dozen weather stations. Fitting a variogram to five points is fitting noise,
and the kriging variance that comes back — the thing that would make kriging
worth the trouble — is derived from that same noise. It produces a more
confident-looking map, not a more accurate one.

The error here is not dominated by the choice of distance kernel anyway. Over
ground like Colorado's it is dominated by **elevation**: Denver sits near
1600 m and the foothills twenty kilometres west are past 2500 m, which is
roughly 9 °F from lapse rate alone. Any purely horizontal interpolator, kriging
included, smears that into nonsense.

So the useful idea is not a better kernel, it is removing the trend first.

## Which parameters, and which not

`APRSWeatherField.Parameter` — the difference is physical, not taste.

- **Pressure** is the best-behaved thing a surface network measures. It varies
  smoothly over hundreds of kilometres, which is why hand-drawn isobars from
  sparse stations worked for a century. It arrives already reduced to sea
  level, so it is **not** height-corrected a second time; a station sending
  raw station pressure from altitude reads ~100 mb low and is rejected as a
  broken sensor rather than allowed to drag the field.
- **Temperature** needs the elevation trend removed first — see below.
- **Humidity** gets plain distance weighting and no trend.
- **Rainfall is deliberately not offered.** Rain cells are kilometres across
  and gauges are tens of kilometres apart, so a smooth surface drawn through a
  handful of them invents storms between the gauges and erases the ones that
  fell between them. Rain stays on the stations that measured it, as numbers.

The picker offers only parameters that at least two heard stations are
currently reporting, so it can never select an empty map.

## The method

1. **Fit a lapse rate** of temperature against station elevation, by least
   squares. Only trusted with at least three stations spanning 200 m or more
   of relief, and only when the slope lands in a physically sane range
   (−0.030…0.005 °F/m). Otherwise the standard environmental lapse rate is
   assumed, and the layer's caption says which happened.
2. **Interpolate the residuals** — what each station reads once its own height
   is accounted for — with inverse-distance weighting, power 2.
3. **Add the trend back** at each output cell using the stored terrain height
   there. Where no elevation is stored the correction is skipped for that
   cell, which produces a smooth field rather than one pretending sea level in
   the mountains.

In geostatistical terms this is the cheap sibling of regression kriging. It
keeps the part that matters — the physical trend — and drops the part that
cannot be estimated at these densities. The residual interpolator is the only
piece that would have to change if station density ever got high enough for
kriging to be fittable.

## What it refuses to do

- **Two stations minimum.** One reading is a reading, not a field; colouring
  from it paints one thermometer across a county.
- **Nothing past 40 km from every station** (`coverageRadiusKm`). Beyond that,
  extrapolation draws the global mean wearing a gradient, which looks exactly
  like data. Confidence fades over the outer third of that radius so the edge
  is a fade rather than a boundary that reads as weather.
- **No sharp isotherms.** The raster is 96 cells square and scaled up
  smoothly. Crisp contours from six stations would be a lie with good edges.
- **Stale readings are excluded.** Only stations whose reading is inside
  `HeardStationMap.weatherFreshWindow` (one hour) contribute.
- The wash is drawn at 22% alpha under the markers. At 42% it read as a sepia
  filter over the whole page and looked more authoritative than the four
  stations behind it.

## Where it appears

The **Weather Field** switch, filed under the APRS traffic family, so on a
multi-radio station it appears under the radio that carries APRS. Its caption
names the station count and whether the lapse rate was fitted or assumed —
two stations and twelve are very different maps and they look identical once
coloured. The switch is disabled with an explanation when too few stations
have been heard to infer anything.

Stations placed at a licence address still contribute. Their thermometer is
real even when their dot is a lookup, and excluding them would throw away half
the readings on a channel where few stations beacon a position.

## Tests

`AXTermTests/Unit/APRS/APRSWeatherFieldTests.swift` — the two-station floor,
the lapse-rate fit and its three fallbacks, interpolation between stations,
the height correction making a cell colder, refusing to answer past the
coverage radius, the confidence fade, and the colour ramp staying in gamut.
