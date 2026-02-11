# AXTerm Network Graph Guide

This guide explains how the Analytics network graph works in AXTerm, how the math is computed, how to use the graph effectively, and how to validate correctness.

## What The Graph Is For

The graph is designed to answer two different operator questions:

1. Direct RF question: "Who can I likely work directly?"
2. Routing/topology question: "How is traffic flowing through the wider network?"

AXTerm separates those questions with explicit edge types and lenses, so the UI does not overstate RF reachability.

## Data Sources And Pipeline

The graph has two sources:

1. `Packets` source:
   1. Uses observed AX.25 packet traffic in the selected timeframe.
   2. Builds a classified relationship graph from evidence in packet paths.
2. `NET/ROM` source:
   1. Uses NET/ROM neighbors and routes (`classic`, `inferred`, `hybrid`).
   2. Optionally overlays packet byte/count evidence for inspector traffic context.

Core build path:

1. Normalize callsigns and map station identity (grouped station vs per-SSID).
2. Filter invalid/service endpoints for graph identity.
3. Build classified edges and directional inspector relationships.
4. Apply lens filtering (`Direct`, `Routed`, `Combined`) to produce the rendered `GraphModel`.
5. Apply view filters (focus, max nodes, min edge where applicable, ignored/simulated endpoints).

Primary implementation files:

- `/Users/rwardrup/dev/AXTerm/AXTerm/Analytics/NetworkGraphBuilder.swift`
- `/Users/rwardrup/dev/AXTerm/AXTerm/Analytics/LinkType.swift`
- `/Users/rwardrup/dev/AXTerm/AXTerm/Analytics/AnalyticsDashboardViewModel.swift`
- `/Users/rwardrup/dev/AXTerm/AXTerm/Analytics/AnalyticsDashboardView.swift`

## Station Identity (Grouping)

Two identity modes exist:

1. `Station`:
   1. Groups SSIDs under base callsign (`ANH`, `ANH-1`, `ANH-15` -> one node).
2. `SSID`:
   1. Keeps each SSID as a distinct node.

This identity mode affects node IDs, adjacency, edge aggregation, and health denominator behavior.

## Callsign Validation And Service Endpoint Filtering

AXTerm intentionally excludes known non-station endpoints from routing identity by default (for example `ID`, `BEACON`, `MAIL`, `QST`, `APRS` families, `WIDE*`, `TRACE*`, `BBS*` patterns), while still allowing tactical routing aliases like `DRL` / `DRLNOD`.

Users can add custom ignored endpoints. Those are treated as service endpoints and removed from graph/routing identity until unignored.

Implementation:

- `/Users/rwardrup/dev/AXTerm/AXTerm/Analytics/CallsignValidator.swift`
- `/Users/rwardrup/dev/AXTerm/AXTerm/Settings/NetworkSettingsView.swift`

## Relationship Types (Evidence Model)

Edge types are explicitly typed:

1. `Direct Peer`:
   1. Bidirectional endpoint traffic with no digipeater path.
2. `Heard Mutual`:
   1. Mutual direct-heard RF evidence (both directions).
3. `Heard Direct`:
   1. One-way direct-heard RF evidence (directional in inspector, undirected in render).
4. `Heard Via`:
   1. Via-mediated observations (digipeater paths), not proof of direct RF.
5. `Infrastructure`:
   1. Reserved low-priority class (for specialized contexts).

Edge precedence avoids duplicates and promotes stronger evidence:

1. `DirectPeer` supersedes weaker alternatives for the same pair.
2. `HeardMutual` supersedes one-way direct edges for the same pair.
3. `HeardVia` is shown when stronger direct evidence is absent.

## Lens Behavior (Packet Source)

Lens mapping is defined in `/Users/rwardrup/dev/AXTerm/AXTerm/Analytics/LinkType.swift`.

1. `Direct` lens:
   1. Shows `DirectPeer`, `HeardMutual`, `HeardDirect`.
   2. Excludes via-mediated edges by definition.
2. `Routed` lens:
   1. Shows `DirectPeer` + `HeardVia`.
   2. View model forces via inclusion on.
3. `Combined` lens:
   1. Shows all link types.
   2. Digipeater-path toggle is configurable here.

Important nuance:

1. `includeViaDigipeaters` controls expansion/promoting of hop-by-hop via nodes/edges.
2. Summary `HeardVia` endpoint relationships are still tracked in classified evidence model.
3. The rendered lens filter decides what is visible.

## NET/ROM Graph Behavior

NET/ROM modes use route/neighbor snapshots instead of packet-derived classification:

1. Neighbor edges map to direct peer style relationships.
2. Route quality is mapped to edge weight.
3. Staleness can dim/hide routes depending on settings.
4. Node sizing reflects route centrality (route involvement count).

## View Filters, Ignore, Simulation, Temporary Show-All

The graph has structural and user filters:

1. Structural:
   1. `Min Edge` and `Max Nodes`.
   2. Focus mode (k-hop neighborhood).
2. Endpoint controls:
   1. Persisted ignore list (settings + right-click flows).
   2. Simulation removals.
   3. Temporary unignore / temporary show-all with restore snapshot.

Hidden-by-filters popover behavior:

1. Displays hidden-count reasons (focus/structural/simulated/ignored).
2. Supports `Show All (Temporary)` and `Restore Filters`.
3. Shows per-node actions:
   1. Temporary show.
   2. Permanent unignore for ignored entries.

Implementation:

- `/Users/rwardrup/dev/AXTerm/AXTerm/Analytics/AnalyticsDashboardView.swift`

## Network Health Math

Health is computed from a canonical graph and hybrid windows, independent of visual filters.

Canonical topology graph:

1. Rebuilt from timeframe packets.
2. Uses fixed `canonicalMinEdge = 2`.
3. Uses unlimited node cap.
4. Ignores current render filters (`Max Nodes`, focus, etc.).

Hybrid windows:

1. Topology metrics use selected timeframe.
2. Activity metrics use fixed 10-minute window (`A1`, `A2`) unless limited by available data.

Formulas (see `/Users/rwardrup/dev/AXTerm/AXTerm/Analytics/NetworkHealthModel.swift`):

1. Topology components:
   1. `C1` main cluster %.
   2. `C2` connectivity % = actual edges / possible edges.
   3. `C3` isolation reduction % = 100 - isolated%.
2. Topology score:
   1. `Topology = 0.5*C1 + 0.3*C2 + 0.2*C3`
3. Activity components:
   1. `A1` active node % (10m active / total).
   2. `A2` packet-rate score normalized to 1.0 pkt/min target, EMA-smoothed.
4. Activity score:
   1. `Activity = 0.6*A1 + 0.4*A2`
5. Final:
   1. `Final = round(0.6*Topology + 0.4*Activity)` clamped to `[0,100]`.

Guards that prevent >100% anomalies:

1. Percent components are clamped to `[0,100]`.
2. Freshness is clamped to `[0,1]`.
3. Total-node denominator is aligned with canonical graph membership to prevent alias-related inflation.

## Why Operators Find This Useful

1. Separates direct-workable links from routed visibility.
2. Prevents false conclusions like "not directly connected means isolated."
3. Lets operators clean local graphs by suppressing local service endpoints.
4. Supports quick what-if simulation before permanently ignoring endpoints.
5. Keeps health score stable while users explore display filters.

## Practical Usage Workflow

1. Start in `Packets + Direct` to inspect probable direct RF neighborhood.
2. Switch to `Packets + Routed` to inspect flow through digipeaters/aliases.
3. Use `Combined` for full evidence context and optional path expansion.
4. If graph is noisy:
   1. Add persistent ignores for local service endpoints.
   2. Use temporary show-all to audit what is hidden.
5. Validate suspicious health changes:
   1. Confirm timeframe change or include-via toggle changed.
   2. Do not assume min/max/focus changes should alter health.

## Validation And Test Coverage

Key tests:

- `/Users/rwardrup/dev/AXTerm/AXTermTests/Unit/Analytics/NetworkGraphRegressionTests.swift`
- `/Users/rwardrup/dev/AXTerm/AXTermTests/Unit/Analytics/NetworkGraphBuilderTests.swift`
- `/Users/rwardrup/dev/AXTerm/AXTermTests/Unit/Analytics/CallsignValidatorTests.swift`
- `/Users/rwardrup/dev/AXTerm/AXTermTests/Unit/Analytics/NetworkHealthScoreTests.swift`
- `/Users/rwardrup/dev/AXTerm/AXTermTests/Unit/Analytics/AnalyticsDashboardViewModelTests.swift`

What these defend:

1. Node retention and stable IDs/order across rebuilds.
2. SSID grouping/splitting correctness.
3. Direct/routed/combined evidence semantics.
4. Service endpoint suppression and custom ignore behavior.
5. Health-score bounds and filter invariance.
6. Snapshot-based metric sanity checks using SQLite fixture data.

## Known Design Tradeoffs

1. Render edges are undirected for readability, while inspector relationships preserve directional evidence where relevant.
2. In packet mode, `HeardVia` summary evidence can exist even when hop-by-hop expansion is off.
3. Degree for certain calculations emphasizes stronger relationships to avoid over-promoting weak one-way evidence.

## Related Docs

- `/Users/rwardrup/dev/AXTerm/Docs/NetworkGraphSemantics.md`
- `/Users/rwardrup/dev/AXTerm/Docs/NetworkGraphUX.md`
- `/Users/rwardrup/dev/AXTerm/Docs/NetworkHealth.md`

## External References

The implementation aligns with established packet-radio and graph-analysis concepts:

- [APRS Protocol Reference 1.0.1](http://www.aprs.org/doc/APRS101.PDF)
- [AX.25 v2.2 protocol reference](https://www.ax25.net/AX25.2.2-Jul%2098-2.pdf)
- [The New-N Paradigm (APRS pathing)](https://www.aprs.org/fix14439.html)
- [NetworkX connected components concepts](https://networkx.org/documentation/stable/reference/algorithms/generated/networkx.algorithms.components.connected_components.html)
- [NetworkX spring layout (Fruchterman-Reingold)](https://networkx.org/documentation/stable/reference/generated/networkx.drawing.layout.spring_layout.html)
- [NetworkX betweenness centrality](https://networkx.org/documentation/stable/reference/algorithms/generated/networkx.algorithms.centrality.betweenness_centrality.html)
