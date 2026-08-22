# Routing Metrics — Quick Reference

This is the reference the metric tooltips point to. The full design document is
[RoutingAndLinkQuality.md](RoutingAndLinkQuality.md); network-health scoring is
in [NetworkHealth.md](NetworkHealth.md).

## df / dr — directional delivery probabilities

- **df**: probability a frame you send across the link is delivered (forward).
- **dr**: probability the acknowledgement path works (reverse).
- Estimated by a time-based EWMA over observed evidence (I-frame progress,
  routing broadcasts, beacons, N(R) advancement, ACK-only frames; retries count
  as failures). `α = max(1 − exp(−Δt/H), 1/(n+1))` with H = 30 min — the
  count-based term is the cold-start warm-up: one packet yields df 0.75, not 1.0.
- When dr is unobservable (UI-only traffic), a conservative dr of 0.99 is
  assumed, so a one-way link can never display as fully confirmed.

## ETX — expected transmissions

```
ETX = 1 / (max(df, 0.05) × max(dr, 0.05)),  clamped to [1.0, 20.0]
```

ETX ≈ 1 is a clean link; ETX 3 means a frame needs three attempts on average.

## Quality (0–255)

```
quality = round(255 / ETX), clamped to [0, 255]
```

Shown in the Link Quality table with a per-row derivation tooltip (df, dr, ETX,
duplicate count, and the formula). Neighbor and route quality follow NET/ROM
semantics (see RoutingAndLinkQuality.md §8): route quality is the standard
`(q_broadcast × q_path + 128) / 256` product and tracks fresh advertisements in
both directions.

## Duplicates

`duplicateCount` counts retransmissions/retries observed on the link. Retries
feed the df estimate as failures; a high count with modest traffic indicates a
struggling link.

## Freshness

Freshness is `100 × recency`: a plateau (95–100% for the first 5 minutes)
followed by a smoothstep decline to 0% at the entry's TTL. TTLs are
configurable in Settings — neighbors default to 6 h, link stats 12 h, routes to
an adaptive TTL (3× the origin's learned broadcast interval) with a 1 h global
fallback. Persisted neighbors past their TTL load with exponentially decayed
quality (half per additional TTL), never zeroed.
