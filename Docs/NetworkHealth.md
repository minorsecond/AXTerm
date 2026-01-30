# Network Health Metrics

This document describes the Network Health panel in AXTerm's Analytics view, including how metrics are computed, what time windows they use, and the rationale behind the hybrid approach.

## Overview

The Network Health panel provides a real-time summary of packet radio network status. It uses a **hybrid time window model** to balance historical context with current activity:

- **Topology metrics** depend on the user-selected timeframe (15m, 1h, 6h, 24h, 7d, or custom)
- **Activity metrics** use a fixed 10-minute window, independent of the selected timeframe

This design prevents UX "whiplash" when users change timeframes. Activity metrics remain stable while topology metrics update to reflect the new historical window.

## Time Window Categories

### Topology Metrics (Timeframe-Dependent)

These metrics reflect the network's structure and history based on the selected timeframe:

| Metric | Label | Description |
|--------|-------|-------------|
| Stations Heard | `Stations (24h)` | Unique stations observed during the selected timeframe |
| Total Packets | `Packets (24h)` | AX.25 frames received during the selected timeframe |
| Main Cluster | `Cluster (24h)` | Percentage of stations in the largest connected component |
| Top Relay Share | `Relay (24h)` | Share of connections involving the busiest digipeater |
| Isolated Stations | - | Stations with no observed connections in the timeframe |

### Activity Metrics (Fixed 10-Minute Window)

These metrics reflect the network's **current** state, independent of the selected timeframe:

| Metric | Label | Description |
|--------|-------|-------------|
| Active Stations | `Active (10m)` | Stations that sent or received packets in the last 10 minutes |
| Packet Rate | `Rate (10m)` | Packets per minute over the last 10 minutes |
| Freshness | - | Ratio of active (10m) stations to total stations in timeframe |

## Health Score Calculation

The overall health score (0-100) uses a weighted hybrid model:

```
Score = Activity (10m) × 25% + Freshness (10m) × 15% +
        Connectivity × 30% + Redundancy × 20% + Stability × 10%
```

### Component Breakdown

**Activity Metrics (40% total)**
- **Activity (25%)**: Based on packet rate. Higher traffic = more active network.
  - Excellent (100): >2 pkt/min
  - Good (85): 1-2 pkt/min
  - Fair (70): 0.5-1 pkt/min
  - Low (50): 0.2-0.5 pkt/min
  - Poor (30): 0.05-0.2 pkt/min

- **Freshness (15%)**: Ratio of active stations (10m) to total stations (timeframe).
  - Score = freshness × 100

**Topology Metrics (60% total)**
- **Connectivity (30%)**: Percentage of stations in the largest connected component.
  - Score = largestComponentPercent (0-100)

- **Redundancy (20%)**: Inverse of relay concentration. Lower concentration = better.
  - ≤30% concentration: 100
  - 31-50%: 70
  - 51-70%: 40
  - >70%: 20

- **Stability (10%)**: Packets per station ratio during the timeframe.
  - Score = min(100, packetsPerStation × 10)

### Rating Thresholds

| Score | Rating |
|-------|--------|
| 80-100 | Excellent |
| 60-79 | Good |
| 40-59 | Fair |
| 1-39 | Poor |
| 0 | Unknown |

## Warnings

Warnings are generated based on specific threshold conditions. Each warning includes the relevant time window in its detail text:

| Warning | Condition | Time Window |
|---------|-----------|-------------|
| Single relay dominance | Top relay >60% of traffic | Timeframe |
| Stale stations | Freshness <0.3 | Hybrid (compares 10m to timeframe) |
| Fragmented network | Main cluster <50% (with >5 stations) | Timeframe |
| Isolated stations | Any nodes with degree == 0 | Timeframe |
| Low activity | Packet rate <0.1/min | 10-minute |

## UI Labels and Tooltips

### Label Format

Topology metrics include the timeframe in their label when space permits:
- `Stations (24h)` instead of `Stations Heard`
- `Cluster (24h)` instead of `Main Cluster`

Activity metrics always show `(10m)`:
- `Active (10m)`
- `Rate (10m)`

### Tooltip Content

Each metric has a tooltip explaining:
1. What the metric measures
2. What time window it uses
3. How to interpret the value

Example tooltips:
- **Stations (24h)**: "Unique stations observed during the 24h window."
- **Active (10m)**: "Stations that have sent or received at least one packet in the last 10 minutes. Independent of selected timeframe."
- **Main Cluster (24h)**: "Percentage of stations in the largest connected group during the 24h window. Higher values indicate a well-connected network."

## Rationale

### Why Hybrid Windows?

**Problem**: Users changing timeframes saw confusing metric swings. Switching from 24h to 1h could make a healthy network look "unhealthy" simply because fewer stations were active in the shorter window.

**Solution**:
- Keep activity metrics (Active, Rate) on a fixed 10-minute window so they always reflect "now"
- Keep topology metrics (Cluster, Relay, Stations) on the selected timeframe so users can analyze historical patterns
- The health score balances both (60% topology + 40% activity) so it remains meaningful regardless of timeframe selection

### Design Principles

1. **Transparency**: Labels always show which time window a metric uses
2. **Stability**: Activity metrics don't jump when changing timeframe
3. **Consistency**: The same metric always uses the same window type
4. **Explainability**: The score breakdown shows how each component contributes

## Test Checklist

Use these checks to verify the implementation works correctly:

- [ ] Change timeframe 24h → 1h: topology metrics update, "Active (10m)" stays stable
- [ ] Health score changes but does not whiplash without explanation
- [ ] Tooltips match displayed windows and calculations
- [ ] Percentage formatting uses dynamic precision (≥10%: 0 decimals, <10%: 1 decimal, <1%: 2 decimals)
- [ ] Warnings include timeframe context in detail text
- [ ] Score explainer popover shows hybrid model breakdown with color coding

## Files

| File | Purpose |
|------|---------|
| `NetworkHealthModel.swift` | Data models and calculation logic |
| `GraphCopy.swift` | UI strings, labels, and tooltips |
| `GraphSidebar.swift` | Sidebar UI rendering |
| `NetworkHealthView.swift` | Score explainer popover |
| `AnalyticsDashboardViewModel.swift` | Integration with view model |
