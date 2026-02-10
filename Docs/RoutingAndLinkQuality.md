# Routing and Link Quality — Reference Guide

This document describes AXTerm's routing intelligence: how link quality is measured,
how routes are selected, and how the system adapts to diverse RF conditions.

---

## 1. ETX and Delivery Probabilities

AXTerm uses ETX (Expected Transmission Count) from the De Couto/Roofnet lineage
to quantify link quality. ETX counts how many transmissions are needed, on average,
to successfully deliver one packet across a link.

### Directional Delivery Probabilities

- **df** — forward delivery probability (A→B succeeds)
- **dr** — reverse delivery probability (B→A succeeds, e.g. ACK returns)

Both are estimated using EWMA (Exponentially Weighted Moving Average):

```
df_t = (1 - α) × df_{t-1} + α × s_fwd
dr_t = (1 - α) × dr_{t-1} + α × s_rev
```

where:

```
α = 1 - exp(-Δt / H)
```

- **H** (half-life): 30 minutes (default for both forward and reverse)
- **Δt**: time since previous observation

This time-based EWMA adapts smoothing to observation frequency — frequent
observations blend slowly (small α), while sparse observations cause larger updates.

### ETX Calculation

```
ETX = 1 / (max(df, 0.05) × max(dr, 0.05))
```

- Clamped to `[1.0, 20.0]`
- When dr is unobservable (UI-only frames), a conservative dr=0.99 is assumed
- The 0.05 floor prevents division-by-zero and caps ETX at 400 (before maxETX clamp)

### Evidence Sources

| Source | Forward Evidence | Reverse Evidence |
|--------|-----------------|------------------|
| I-frame data progress | weight=1.0 | — |
| Routing broadcast | weight=0.8 | — |
| UI beacon | weight=0.4 | — |
| ACK-only (RR/RNR) | — | weight=0.1 |
| N(R) progress | — | weight=0.6 |
| Retry/duplicate | penalty (value=0.0) | — |

---

## 2. Composite Quality Score (0–255)

Quality is mapped from ETX for UI display:

```
quality = round(255 / ETX)
```

Clamped to `[0, 255]`.

For the full composite score with recency and duplicate weighting (used in
CLAUDE.md §8 for UI ranking):

```
g_etx  = 1 / ETX
g_dups = 1 - dups

goodness =
  (0.30 × df) +
  (0.30 × dr) +
  (0.30 × g_etx) +
  (0.10 × g_dups)

goodness = goodness × recency
quality  = round(255 × clamp(goodness, 0, 1))
```

This composite score is for **UI ranking only**; routing logic uses raw ETX/df/dr.

---

## 3. Route Selection and Hysteresis

### The Problem: Route Flapping

Without hysteresis, if two routes to the same destination have similar quality
(e.g. 187 vs 190), the preferred route can flip every purge cycle (60s). This
causes:

- Unnecessary path changes mid-session
- Possible packet reordering
- Wasted digipeater capacity

Real-world example: On an AREDN mesh, two paths to a node via different
digipeaters may oscillate between ETX 1.8 and 2.0 depending on instantaneous
QRM. Without hysteresis, every quality update triggers a route switch.

### AXTerm's Approach: Sticky Route with Margin

AXTerm uses a **sticky preferred route** with two conditions for switching:

1. **Quality margin**: A new route must exceed the current preferred route's
   quality by at least `hysteresisMargin` (default: 12%)
2. **Hold time**: At least `hysteresisHoldSeconds` (default: 120s) must have
   elapsed since the last route switch

Both conditions must be met to trigger a switch. If the preferred route expires
(falls off the routing table), the best remaining route is selected immediately.

### Comparison with Other Protocols

| Protocol | Mechanism |
|----------|-----------|
| **Babel** (RFC 8966 §3.5.2) | Feasibility condition: new route must have metric strictly less than the feasibility distance |
| **BATMAN IV** | Sliding window OGM sequencing; route switch requires sustained better TQ |
| **BATMAN V** | Per-interface throughput metric with hysteresis built into ELP |
| **OLSR** | Hysteresis function with thresholds: link accepted at 0.75, rejected below 0.45 |
| **AXTerm** | Sticky route + quality margin + hold timer |

---

## 4. Adaptive TTL

### The Problem: One Size Doesn't Fit All

A flat 30-minute TTL works for VHF digipeaters that beacon every few minutes,
but is too aggressive for:

- **HF links** heard hourly (e.g. Winlink gateways, long-haul NET/ROM)
- **Sparse hilltop digipeaters** with 15-minute beacon intervals

And too generous for:
- **Chatty VHF digipeaters** heard every 10 seconds

### AXTerm's Approach: Inter-Arrival Tracking

AXTerm tracks the average inter-arrival time per directional link using EWMA
(α=0.3). The effective TTL is then:

```
effectiveTTL = max(baseTTL, min(maxTTL, multiplier × avgInterArrival))
```

Defaults:
- `baseTTL` = 1800s (30 min, from `slidingWindowSeconds`)
- `multiplier` = 6.0 (6× inter-arrival)
- `maxTTL` = 7200s (2 hours)

### Examples

| Link Type | Avg Inter-Arrival | Effective TTL |
|-----------|------------------|---------------|
| VHF digi (30s beacons) | 30s | 1800s (base wins) |
| VHF digi (5min beacons) | 300s | 1800s (base wins) |
| HF link (20min) | 1200s | 7200s (6×1200) |
| HF link (60min) | 3600s | 7200s (cap wins) |

### Comparison with Other Protocols

- **BATMAN V**: Uses per-interface ELP intervals (150ms–10s) with OGM intervals
  scaled per-interface. Effectively adapts timing per link type.
- **Babel**: Hello intervals are per-interface and configurable (4s default, up
  to minutes for lossy links). Route expiry is 3.5× hello interval.
- **Classic NET/ROM**: Fixed obsolescence count (6 broadcast cycles), no
  time-based adaptation.

---

## 5. Soft Expiry and Tombstones

### The Problem: Hard Purge Loses Knowledge

Immediately removing link stats and evidence at TTL expiry discards topology
knowledge that could be revived by a late burst of packets. This is especially
harmful for HF links with long inter-arrival times.

### AXTerm's Approach: Two-Phase Expiry

**Phase 1 — Tombstone**: When all observations for a link expire from the
sliding window, the entry is *tombstoned* rather than removed:
- `tombstonedAt` is set to the current date
- EWMA estimates are cleared (quality returns 0)
- The entry remains in the stats dictionary

**Phase 2 — Removal**: After the tombstone window elapses (equal to the
effective TTL for link stats, or `inferredRouteHalfLifeSeconds × tombstoneWindowMultiplier`
for evidence), the entry is fully removed from memory.

**Revival**: If new evidence arrives during the tombstone window, the tombstone
is cleared and normal tracking resumes. This prevents unnecessary re-learning
of link characteristics.

### Comparison with Other Protocols

| Protocol | Expiry Model |
|----------|-------------|
| **Babel** | Route retraction: metric set to infinity (0xFFFF), held for garbage collection timer, then flushed |
| **BATMAN IV** | Sliding window: OGMs age out of the window, TQ decays to 0, then entry purged |
| **Classic NET/ROM** | Obsolescence count: decremented each broadcast cycle, removed at 0. No tombstone phase. |
| **AXTerm** | Two-phase: tombstone (quality=0, entry retained) → removal after window |

---

## 6. Protocol Comparison Table

| Feature | AXTerm | Babel (RFC 8966) | BATMAN IV | BATMAN V | OLSR | Classic NET/ROM |
|---------|--------|-----------------|-----------|----------|------|----------------|
| **Metric** | ETX (df×dr) | ETX or custom | TQ (transmit quality) | Throughput (ELP) | ETX + hysteresis | Quality (0-255) |
| **Route stability** | Sticky + margin + hold | Feasibility condition | Sliding window OGM | Per-interface ELP | Hysteresis function | None (best quality wins) |
| **TTL model** | Adaptive (inter-arrival × multiplier) | 3.5× hello interval | Fixed OGM interval | Per-interface ELP | Fixed hello interval | Fixed obsolescence count |
| **Expiry model** | Two-phase tombstone | Retraction → GC | Window aging | Window aging | Validity timer | Obsolescence countdown |
| **Directional** | Yes (A→B ≠ B→A) | Yes | No (symmetric TQ) | Yes (throughput) | No | No |
| **Evidence types** | I-frame, ACK, beacon, N(R) | Hello, IHU | OGM | ELP + OGM | Hello, TC | Routing broadcast only |

---

## 7. Configuration Reference

### NetRomConfig (Route Selection)

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `hysteresisMargin` | 0.12 | 0.0–1.0 | Fraction by which new route must exceed current to trigger switch. Set to 0 to disable. |
| `hysteresisHoldSeconds` | 120.0 | 0–600 | Minimum seconds before allowing a route switch |
| `neighborTTLSeconds` | 1800 | 300–7200 | Base neighbor TTL |
| `routeTTLSeconds` | 1800 | 300–7200 | Base route TTL |
| `neighborBaseQuality` | 80 | 0–255 | Initial quality for new neighbors |
| `minimumRouteQuality` | 32 | 0–255 | Minimum combined quality to accept a route |
| `maxRoutesPerDestination` | 3 | 1–10 | Maximum alternate routes per destination |

### LinkQualityConfig (Link Estimation)

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `slidingWindowSeconds` | 1800 | 300–7200 | Base observation window / minimum TTL |
| `forwardHalfLifeSeconds` | 1800 | 300–7200 | EWMA half-life for df |
| `reverseHalfLifeSeconds` | 1800 | 300–7200 | EWMA half-life for dr |
| `adaptiveTTLMultiplier` | 6.0 | 2.0–20.0 | Multiplier for inter-arrival → effective TTL |
| `maxAdaptiveTTLSeconds` | 7200 | 1800–86400 | Maximum adaptive TTL (cap) |
| `initialDeliveryRatio` | 0.5 | 0.0–1.0 | Cold-start df/dr estimate |
| `minDeliveryRatio` | 0.05 | 0.01–0.5 | Floor for ETX denominator |
| `maxETX` | 20.0 | 1.0–100.0 | ETX ceiling |
| `maxObservationsPerLink` | 200 | 10–1000 | Ring buffer capacity |

### NetRomInferenceConfig (Passive Inference)

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `inferredRouteHalfLifeSeconds` | 1800 | 300–7200 | Evidence validity period |
| `tombstoneWindowMultiplier` | 1.0 | 0.5–3.0 | Tombstone window = halfLife × multiplier |
| `evidenceWindowSeconds` | 5 | 1–60 | Minimum interval between reinforcements |
| `inferredBaseQuality` | 60 | 0–255 | Initial quality for inferred routes |
| `reinforcementIncrement` | 20 | 0–100 | Quality boost per reinforcement |
| `retryPenaltyMultiplier` | 0.7 | 0.0–1.0 | Score multiplier on retry detection |
