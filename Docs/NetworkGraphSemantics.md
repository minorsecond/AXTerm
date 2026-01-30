# Network Graph Semantics

This document describes how AXTerm interprets and displays network relationships in the graph view.

## Overview

The network graph distinguishes between different types of connections to help users understand:
1. Who they can communicate with directly (RF)
2. Who they can reach through the network (via digipeaters)
3. How packets flow through the network

## Relationship Types

### Direct Peer

**Definition**: Confirmed endpoint-to-endpoint packet exchange.

A station P is a **Direct Peer** of station S if packets exist with:
- `from=S, to=P` OR `from=P, to=S`
- No digipeaters in the path (empty via field)
- Packet count >= threshold (view's Min Edge slider)

**Visual**: Solid line (strongest weight)

**Tooltip**: "Endpoint-to-endpoint traffic involving this station within the selected timeframe. Excludes digipeater-only paths."

**What it means**: True bidirectional communication. Both stations have exchanged packets directly.

### Heard Direct

**Definition**: Likely direct RF reception (no digipeaters in path).

A station X is **Heard Direct** by station S if:
- S has decoded packets from X
- Those packets have an empty via path (no digipeaters)
- The HeardDirect eligibility score exceeds the threshold

**Visual**: Dotted line (lighter weight)

**Tooltip**: "Frames decoded directly from this station (no digipeaters in the path). Indicates likely RF reachability."

**What it means**: Station S can likely hear station X directly via RF. A direct connection is plausible but not confirmed as bidirectional.

### Heard Via

**Definition**: Observed only through digipeater paths.

A station X is **Heard Via** by station S if:
- S has seen packets from/to X
- All observed packets had non-empty via paths
- X does not qualify as HeardDirect

**Visual**: Dashed line (subdued weight)

**Tooltip**: "Frames observed via digipeaters. Shows network visibility, not direct RF reachability."

**What it means**: Station X is reachable on the network, but there's no evidence of direct RF reception. Do NOT infer RF reachability from this.

### Infrastructure

**Definition**: BEACON, ID, or BBS traffic.

Traffic where the destination is:
- `ID`
- `BEACON`
- `BBS*`

**Visual**: Very subdued or hidden

**What it means**: Standard infrastructure announcements. Not counted as peer connections.

## HeardDirect Scoring

To qualify as HeardDirect, a station must meet eligibility thresholds and receive a score above the minimum.

### Eligibility Requirements

| Parameter | Default | Description |
|-----------|---------|-------------|
| `minDirectMinutes` | 2 | Minimum distinct 5-minute buckets with direct reception |
| `minDirectCount` | 3 | Minimum number of directly received packets |

### Score Calculation

```
normMinutes = clamp(directMinutes / targetMinutes, 0..1)
normCount = clamp(directCount / targetCount, 0..1)
baseScore = 0.6 × normMinutes + 0.4 × normCount
recencyBoost = clamp(1 - (lastHeardAge / recencyWindow), 0..1) × 0.15
finalScore = clamp(baseScore + recencyBoost, 0..1)
```

### Tunable Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `targetMinutes` | 10 | Minutes for full normalization |
| `targetCount` | 20 | Count for full normalization |
| `recencyWindow` | 300s (5 min) | Window for recency boost |
| `maxRecencyBoost` | 0.15 | Maximum recency bonus |
| `minimumScore` | 0.25 | Threshold to qualify as HeardDirect |

## Graph View Modes

The view mode selector controls which relationship types are displayed.

### Connectivity Mode (Default)

**Purpose**: "Who can I directly work with?"

- Shows: Direct Peers (emphasized), Heard Direct
- Hides: Heard Via (unless toggled)
- Best for: Understanding direct RF relationships

### Routing Mode

**Purpose**: "How do packets flow?"

- Shows: Direct Peers, Heard Via (emphasized)
- Emphasizes: Digipeater paths and topology
- Best for: Understanding network routing

### All Mode

**Purpose**: Complete picture

- Shows: All relationship types
- Visual hierarchy: Direct Peer > Heard Direct > Heard Via > Infrastructure

## Inspector Sections

When a node is selected, the inspector shows relationships grouped by type:

### Direct Peers Section

**Header**: "Direct Peers"
**Tooltip**: "Stations you've exchanged packets with directly (endpoint-to-endpoint). True bidirectional communication."

Displays:
- Station callsign
- Packet count
- Last heard time

### Heard Direct Section

**Header**: "Heard Direct"
**Tooltip**: "Stations you've decoded directly without digipeaters. A direct RF connection is plausible."

Displays:
- Station callsign
- Packet count
- Last heard time
- HeardDirect score (for debugging)

### Heard Via Section

**Header**: "Heard Via"
**Tooltip**: "Stations observed through digipeaters. Reachable on the network, but not proof of direct RF reception."

Displays:
- Station callsign
- Packet count
- Last heard time
- Via digipeaters (e.g., "via DRL, K0NTS-7")

## Edge Legend

A small legend in the graph header explains line styles:

```
━━━━  Direct Peer
┄┄┄┄  Heard Direct (likely RF)
----  Heard Via (digipeaters)
```

Clicking the "?" button shows a popover with full definitions.

## View Filter Behavior

| Filter | Affects View? | Affects Health? |
|--------|---------------|-----------------|
| Min Edge slider | ✅ Yes (Direct Peer edges) | ❌ No |
| Max Node count | ✅ Yes (node limit) | ❌ No |
| Include Via Digipeaters | ✅ Yes (Heard Via edges) | ✅ Yes |
| View Mode | ✅ Yes (which types shown) | ❌ No |

**Important**: The Min Edge slider filters which Direct Peer edges are **drawn**, but the inspector always shows true counts regardless of the slider setting.

## Selection & Zoom Behavior

### Default Behavior

- Single click: Select node, show inspector
- Selection does NOT auto-zoom aggressively
- Full cluster remains faintly visible
- Selected node and edges are highlighted

### Explicit Actions

- **Fit Graph**: Zoom to show all visible nodes (default toolbar button)
- **Zoom to Selection**: Explicit action to zoom to selected node's neighborhood
- **Clear Selection (X)**: Deselect and return to Fit Graph extent

### Focus Mode

When focus mode is enabled:
- Shows k-hop neighborhood from anchor
- "Exit Focus" button is always visible
- Network Health panel remains stable (not hidden)
- Breadcrumb shows anchor node and hop count

## Why This Matters

### The Problem

Previously, the graph implied "connected" = "direct peer exchange". This made users think they were isolated when they simply lacked direct peer conversations but were still part of the network via digipeaters.

**Example**: K0EPI shows one blue edge to WH6ANH. This is true for direct endpoint exchanges, but K0EPI is still part of a wider network via digipeaters and infrastructure traffic.

### The Solution

By explicitly modeling relationship types:
1. Users see their true direct peer connections
2. Users understand which stations they can likely hear directly
3. Users know which stations are only reachable via digipeaters
4. No false implications about RF reachability

## Implementation Files

| File | Purpose |
|------|---------|
| `LinkType.swift` | Relationship type enums and scoring |
| `NetworkGraphBuilder.swift` | Builds classified graph with edge types |
| `GraphCopy.swift` | UI strings for relationship types |
| `GraphSidebar.swift` | Inspector with relationship sections |

## Test Checklist

- [ ] Direct Peer edges require bidirectional traffic without via path
- [ ] Heard Direct edges have empty via path and meet eligibility
- [ ] Heard Via edges only shown when packets have via path
- [ ] View mode filters correct edge types
- [ ] Inspector shows correct sections with proper tooltips
- [ ] Edge legend displays correctly
- [ ] Selection does not auto-zoom aggressively
- [ ] Focus mode has clear exit mechanism
- [ ] Min Edge slider affects view but not inspector counts
- [ ] Include Via Digipeaters toggle affects Heard Via edges
