# Network Health Scoring

This document describes AXTerm's composite network health scoring system.

## Overview

Network Health provides a 0-100 score indicating the overall health and activity of the observed packet radio network. The score uses a **hybrid time window model** and a **canonical topology graph** to ensure stability and accuracy.

## Key Design Principles

### 1. Canonical Topology Graph

Health topology metrics are computed from a **canonical graph** that:
- Uses `canonicalMinEdge = 1` (fixed, not the view slider) — any observed link is
  topology evidence. Requiring 2+ frames made a station heard once read as
  "isolated" (a false statement) and produced a score cliff between the first and
  second packet of a pair.
- Has no max-node limit (shows full network topology)
- Applies the `includeViaDigipeaters` toggle
- **Ignores** view-only filters (Min Edge slider, Max Node count)

This ensures the health score remains stable when users adjust view filters.

### 2. Hybrid Time Windows

- **Topology metrics**: Based on user-selected timeframe (e.g., 24h, 1h)
- **Activity metrics**: 10-minute window, clamped to the timeframe when shorter.
  A1's numerator and denominator draw on consistent windows; earlier versions let
  a sub-10-minute timeframe silently saturate A1 at 100.

### 3. Determinism

The calculator is a pure function: identical inputs always produce the identical
score. The 10-minute rate window is itself the smoothing — there is no cross-call
EMA state (a per-invocation EMA made the displayed rate depend on how often the
UI happened to recompute). When the app has been listening for less than the
window, the rate divides by the observed span instead of the full window.

### 4. Sample Gate

Below **3 stations or 10 packets** in the timeframe the score is not emitted:
the panel reports **Unknown** with an explanatory reason. Two stations
exchanging two packets used to rate "Excellent" (87) — a degenerate sample must
not outrank a functioning 40-station network.

## Formula

### Topology Score (60% of final)

```
TopologyScore = 0.5×C1 + 0.3×C2 + 0.2×C3
```

Where:
- **C1 (Main Cluster %)**: Largest connected component / total nodes × 100
- **C2 (Connectivity %)**: meanDegree / targetMeanDegree × 100 (capped at 100)
  - `meanDegree = 2 × edges / n`; `targetMeanDegree = 3.0`
  - Mean degree is size-invariant. The old density formula
    (`edges / n(n-1)/2`) decays as O(1/n) for bounded-degree RF networks, which
    punished network growth and capped real networks near 82/100 while scoring a
    two-node graph 100.
  - ~3 links per station gives path redundancy without saturating a shared channel.
- **C3 (Isolation Reduction)**: 100 - (% stations with no observed links)
  - Higher is better; 100 means every heard station has at least one link.
  - An empty network scores 0 here (it used to score 100, lifting a dead network
    to 12/100 "Poor" with a "Network operational" reason).

### Activity Score (40% of final)

```
ActivityScore = 0.6×A1 + 0.4×A2
```

Where:
- **A1 (Active Nodes %)**: Stations heard in last 10m / total timeframe nodes × 100
  (the 10m window is clamped to the timeframe when the timeframe is shorter)
- **A2 (Packet Rate Score)**: trapezoid against channel capacity
  - 0 at 0 pkt/min, ramps to 100 at `idealRate = 1.0 pkt/min`
  - holds 100 through `congestionOnsetRate = 30 pkt/min`
  - declines linearly to `saturatedScore = 20` at `saturatedRate = 60 pkt/min`
  - Rationale: a ~200-byte AX.25 frame occupies ~1.4 s of air time at 1200 baud,
    so ~30 frames/min is already heavy CSMA contention and ~40/min approaches
    100% channel occupancy. A monotonically increasing score would rate a
    collision-saturated channel as healthier than a normal one.

### Final Score

```
NetworkHealthScore = round(0.6×TopologyScore + 0.4×ActivityScore)
```

## Metrics Reference

### Topology Metrics (Timeframe-Dependent, Canonical Graph)

| Metric | Description | Weight |
|--------|-------------|--------|
| C1: Main Cluster | % of nodes in largest connected component | 30% of final |
| C2: Connectivity | mean degree vs target of 3 | 18% of final |
| C3: Isolation Reduction | 100 - % stations with no links (higher = better) | 12% of final |

### Activity Metrics (10-Minute Window)

| Metric | Description | Weight |
|--------|-------------|--------|
| A1: Active Nodes | % of stations heard in last 10 minutes | 24% of final |
| A2: Packet Rate | Rate vs channel capacity (100 from 1–30 pkt/min) | 16% of final |

## Stability Guarantees

The health score is **stable under view filter changes**:

| Setting | Affects Health? |
|---------|-----------------|
| Timeframe selector | ✅ Yes (topology metrics) |
| Include Via Digipeaters toggle | ✅ Yes (canonical graph) |
| Time passing | ✅ Yes (activity metrics) |
| Min Edge slider | ❌ No (view-only) |
| Max Node count | ❌ No (view-only) |

## Rating Thresholds

| Score | Rating |
|-------|--------|
| 80-100 | Excellent |
| 60-79 | Good |
| 40-59 | Fair |
| 1-39 | Poor |
| 0 | Unknown |

Below the sample gate (3 stations / 10 packets) the rating is always **Unknown**.

## Warnings

The system generates contextual warnings:

| Warning | Condition | Time Window |
|---------|-----------|-------------|
| Single relay dominance | >60% of network *links* involve one station, graph >4 nodes | Timeframe |
| Stale stations | <30% freshness, only for timeframes ≤ 1h (at 24h it would be a tautology) | Hybrid (10m vs timeframe) |
| Fragmented network | <50% in main cluster (with >5 stations) | Timeframe |
| Isolated stations | Stations heard with no observed links | Timeframe |
| Low activity | <0.1 packets/minute | 10-minute |

## UI Labels and Tooltips

### Label Format

Topology metrics include the timeframe in their label:
- `Stations (24h)` - Unique stations in canonical graph
- `Cluster (24h)` - C1: Main cluster percentage
- `Connect (24h)` - C2: Connectivity ratio
- `Isolation (24h)` - C3: Isolation reduction

Activity metrics always show `(10m)`:
- `Active (10m)` - A1: Active nodes percentage
- `Rate (10m)` - A2: Packet rate (EMA-smoothed)

### Key Tooltip Messages

- **Header**: "Composite score combining network topology (selected timeframe) and recent activity (last 10 minutes). View filters (Min Edge, Max Nodes) don't affect this score."
- **Main Cluster**: "C1: Percentage of stations in the largest connected group. Computed from the canonical graph."
- **Connectivity**: "C2: Average links per station relative to a target of 3. Formula: meanDegree / 3 × 100."
- **Active (10m)**: "A1: Stations heard in the last 10 minutes. The activity score uses this as a share of all timeframe stations."
- **Rate (10m)**: "A2: Packets per minute over the last 10 minutes. Scores 100 from 1 to 30 pkt/min, then declines toward saturation."

## Implementation Notes

### Files

| File | Purpose |
|------|---------|
| `NetworkHealthModel.swift` | Data models, formula, and calculation logic |
| `GraphCopy.swift` | UI strings, labels, and tooltips |
| `GraphSidebar.swift` | Sidebar UI rendering |
| `NetworkHealthView.swift` | Score explainer popover |
| `AnalyticsDashboardViewModel.swift` | Integration with view model |

### Caching

Health is recalculated when:
- Graph model changes
- Timeframe changes
- `includeViaDigipeaters` toggle changes

The canonical graph is built on-demand for each calculation using `NetworkHealthCalculator.buildCanonicalGraph()`. The calculation is deterministic — recomputing with identical inputs cannot change the score.

### Performance

- Graph building: O(E) where E = packet count
- BFS for largest component: O(V + E)
- Connectivity ratio: O(1) using edge count
- EMA smoothing: O(1) per update

## References

Composite health scoring approach inspired by network monitoring systems such as [Optigo Networks](https://optigo.net/), which aggregate multiple health checks into a single score.

## Test Checklist

- [ ] Health score stable under Min Edge slider changes
- [ ] Health score stable under Max Node count changes
- [ ] Topology metrics update when timeframe changes
- [ ] Activity metrics stay on 10m window (unless TF < 10m)
- [ ] `includeViaDigipeaters` toggle changes topology metrics appropriately
- [ ] Tooltips accurately describe behavior and mention canonical graph
- [ ] No main-thread stalls when packets stream in
- [ ] Packet rate is deterministic for identical inputs
- [ ] Warnings include correct timeframe labels
- [ ] Score explainer popover shows C1/C2/C3/A1/A2 breakdown
- [ ] Percentage formatting uses dynamic precision (≥10%: 0 decimals, <10%: 1 decimal, <1%: 2 decimals)
