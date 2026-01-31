# Network Health Scoring

This document describes AXTerm's composite network health scoring system.

## Overview

Network Health provides a 0-100 score indicating the overall health and activity of the observed packet radio network. The score uses a **hybrid time window model** and a **canonical topology graph** to ensure stability and accuracy.

## Key Design Principles

### 1. Canonical Topology Graph

Health topology metrics are computed from a **canonical graph** that:
- Uses `canonicalMinEdge = 2` (fixed, not the view slider)
- Has no max-node limit (shows full network topology)
- Applies the `includeViaDigipeaters` toggle
- **Ignores** view-only filters (Min Edge slider, Max Node count)

This ensures the health score remains stable when users adjust view filters.

### 2. Hybrid Time Windows

- **Topology metrics**: Based on user-selected timeframe (e.g., 24h, 1h)
- **Activity metrics**: Fixed 10-minute window (unless timeframe < 10m)

This prevents UX "whiplash" when changing timeframes - activity metrics stay stable.

### 3. Stability via EMA Smoothing

Packet rate uses Exponential Moving Average (EMA) smoothing to prevent spiky behavior:
```
smoothedRate = α × currentRate + (1-α) × previousRate
α = 0.25
```

## Formula

### Topology Score (60% of final)

```
TopologyScore = 0.5×C1 + 0.3×C2 + 0.2×C3
```

Where:
- **C1 (Main Cluster %)**: Largest connected component / total nodes × 100
- **C2 (Connectivity Ratio %)**: actualEdges / possibleEdges × 100 (capped at 100)
  - `possibleEdges = n×(n-1)/2` for undirected graph
- **C3 (Isolation Reduction)**: 100 - (% isolated nodes)
  - Higher is better; 100 means no isolated stations

### Activity Score (40% of final)

```
ActivityScore = 0.6×A1 + 0.4×A2
```

Where:
- **A1 (Active Nodes %)**: Stations heard in last 10m / total nodes × 100
- **A2 (Packet Rate Score)**: min(100, packetRate / idealRate × 100)
  - `idealRate = 1.0 packets/minute`

### Final Score

```
NetworkHealthScore = round(0.6×TopologyScore + 0.4×ActivityScore)
```

## Metrics Reference

### Topology Metrics (Timeframe-Dependent, Canonical Graph)

| Metric | Description | Weight |
|--------|-------------|--------|
| C1: Main Cluster | % of nodes in largest connected component | 30% of final |
| C2: Connectivity | % of possible edges that exist | 18% of final |
| C3: Isolation Reduction | 100 - % isolated nodes (higher = better) | 12% of final |

### Activity Metrics (10-Minute Window)

| Metric | Description | Weight |
|--------|-------------|--------|
| A1: Active Nodes | % of stations heard in last 10 minutes | 24% of final |
| A2: Packet Rate | Normalized rate (ideal = 1.0 pkt/min), EMA-smoothed | 16% of final |

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

## Warnings

The system generates contextual warnings:

| Warning | Condition | Time Window |
|---------|-----------|-------------|
| Single relay dominance | >60% of traffic through one station | Timeframe |
| Stale stations | <30% freshness | Hybrid (10m vs timeframe) |
| Fragmented network | <50% in main cluster (with >5 stations) | Timeframe |
| Isolated stations | Nodes with degree=0 in canonical graph | Timeframe |
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
- **Main Cluster**: "C1: Percentage of stations in the largest connected group. Computed from canonical graph (minEdge=2)."
- **Connectivity**: "C2: Percentage of possible links that exist. Formula: actualEdges / possibleEdges × 100."
- **Active (10m)**: "A1: Percentage of stations heard in the last 10 minutes. Independent of selected timeframe."
- **Rate (10m)**: "A2: Packets per minute, EMA-smoothed for stability. Normalized to ideal rate of 1.0 pkt/min."

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

The canonical graph is built on-demand for each calculation using `NetworkHealthCalculator.buildCanonicalGraph()`.

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
- [ ] EMA smoothing prevents packet rate spikes
- [ ] Warnings include correct timeframe labels
- [ ] Score explainer popover shows C1/C2/C3/A1/A2 breakdown
- [ ] Percentage formatting uses dynamic precision (≥10%: 0 decimals, <10%: 1 decimal, <1%: 2 decimals)
