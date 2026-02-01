# Network Graph UX Specification

This document describes the user experience architecture for AXTerm's network graph visualization, following Apple Human Interface Guidelines (HIG) for macOS.

## Core Principles

1. **Visual Stability**: The sidebar has a fixed width and never disappears. Tab switching does not cause layout reflow.
2. **Predictable Camera**: The graph viewport only changes on explicit user actions (Fit, Reset). Selection changes never auto-pan or auto-zoom.
3. **Clear State Hierarchy**: Selection, Focus, and View are independent concepts with distinct controls.
4. **Truthful Tooltips**: Every control has a tooltip that accurately describes its behavior.

---

## State Model

### Selection State
- **What it is**: The set of nodes the user has clicked or box-selected.
- **Visual indicator**: Selected nodes are highlighted; selection count shown in toolbar.
- **Behavior**: Clicking a node selects it. Shift+click adds to selection. Clicking background clears selection.
- **Camera effect**: None. Selection never moves the camera.

### Focus State (Filter Lens)
- **What it is**: A neighborhood filter centered on an "anchor" node.
- **Visual indicator**: Focus pill in toolbar showing "N hops from [Callsign]".
- **Behavior**: When enabled, only nodes within N hops of the anchor are visible.
- **Independence**: Focus anchor is separate from selection. You can focus on one node while inspecting another.

### View State
- **What it is**: Camera position (pan) and zoom level.
- **Controls**: "Fit to Nodes" and "Reset View" buttons.
- **Behavior**: Only changes via explicit user actions.

---

## Control Reference

### Toolbar Controls

| Control | Label | Action | Tooltip |
|---------|-------|--------|---------|
| Fit | "Fit" | Zooms viewport to fit all currently visible nodes (respects focus filter) | "Zoom to fit all visible nodes in the viewport." |
| Reset | "Reset" | Resets pan and zoom to defaults; does not affect selection or focus | "Reset pan and zoom to default. Does not affect selection or focus." |
| Clear | "Clear" | Clears selection and fits view to all visible nodes | "Deselect all nodes." |
| Focus Pill | "[N] hops from [Name]" | Opens focus settings popover | "Showing N-hop neighborhood of [Name]. Click to adjust." |
| × (Exit Focus) | — | Exits focus mode | "Exit focus mode and show all nodes." |

### Sidebar: Overview Tab

| Control | Label | Action | Tooltip |
|---------|-------|--------|---------|
| Health Score | "[Score]/100" | — | "Composite health score (0–100) based on activity, freshness, connectivity, redundancy, and stability." |
| Stations Heard | "Stations Heard" | — | "Total unique amateur radio stations observed in the current timeframe." |
| Active (10m) | "Active (10m)" | — | "Stations that have sent or received at least one packet in the last 10 minutes." |
| Total Packets | "Total Packets" | — | "Total AX.25 frames received during this session." |
| Packets/min | "Packets/min" | — | "Average packet rate over the last 10 minutes." |
| Main Cluster | "Main Cluster" | — | "Percentage of stations in the largest connected group." |
| Top Relay | "Top Relay" | — | "Percentage of connections involving the busiest relay station." |
| Focus Primary Hub | "Focus Primary Hub" | Selects and focuses on hub node | "Select and focus on the most connected node based on the current hub metric." |
| Hub Metric Picker | "Hub Metric" | Selects metric for hub identification | "Choose how to identify the primary hub node." |
| Show Active (10m) | "Show Active (10m)" | Selects all recently active nodes | "Select all stations that have sent or received packets in the last 10 minutes." |
| Export Summary | "Export Summary" | Copies health summary to clipboard | "Copy a text summary of network health metrics to the clipboard." |

### Sidebar: Inspector Tab

| Control | Label | Action | Tooltip |
|---------|-------|--------|---------|
| Focus Around This Node | "Focus Around This Node" | Sets node as anchor and enables focus | "Filter the graph to show only nodes within the specified hop distance of this station." |
| Clear Selection | "Clear Selection" | Deselects node, fits view | "Deselect this node." |

---

## Network Health Metrics

### Overall Score (0–100)
Weighted composite of five factors:
- **Activity (25%)**: Based on packet rate. >2 pkt/min = 100, <0.05 pkt/min = 0.
- **Freshness (20%)**: Ratio of active stations (last 10m) to total stations.
- **Connectivity (25%)**: Percentage of nodes in the largest connected component.
- **Redundancy (20%)**: Inverse of top relay concentration. ≤30% = 100.
- **Stability (10%)**: Packets per station ratio (capped at 100).

### Rating Tiers
- **Excellent**: 80–100
- **Good**: 60–79
- **Fair**: 40–59
- **Poor**: 1–39
- **Unknown**: 0

### Individual Metrics

| Metric | Definition |
|--------|------------|
| Stations Heard | Count of unique node IDs in the graph |
| Active (10m) | Count of stations with packet activity in last 10 minutes |
| Total Packets | Total AX.25 frames in current timeframe |
| Packets/min | Packets in last 10 minutes ÷ 10 |
| Main Cluster % | Nodes in largest connected component ÷ total nodes × 100 |
| Top Relay Share | Edges involving highest-degree node ÷ total edges × 100 |

### Percentage Formatting
- ≥10%: 0 decimal places (e.g., "85%")
- 1–<10%: 1 decimal place (e.g., "5.2%")
- <1%: 2 decimal places (e.g., "0.45%")

---

## Hub Metrics

| Metric | Algorithm | Use Case |
|--------|-----------|----------|
| Degree | Node with max `degree` (connection count) | Find the most connected station |
| Traffic | Node with max `inCount + outCount` | Find the busiest station by packet volume |
| Bridges | Node with max `degree / avg_neighbor_degree` | Find stations connecting separate clusters |

---

## SSID Handling

### Current Behavior
Each callsign+SSID combination (e.g., K0EPI-7, K0EPI-10) is a distinct node.

### Display
- Node labels show the suffix portion for brevity (e.g., "EPI-7" for "K0EPI-7").
- Full callsign shown in Inspector when selected.

### Future: SSID Grouping (Not Yet Implemented)
When implemented, stations with the same base callsign would be grouped, with a badge showing "N SSIDs" and details in the inspector.

---

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Escape | Clear selection |
| Cmd+A | Select all visible nodes |
| Cmd+0 | Fit to nodes |

---

## Manual Test Checklist

### Selection Behavior
- [ ] Clicking a node selects it without moving the camera
- [ ] Shift+clicking adds to selection without moving the camera
- [ ] Clicking background clears selection
- [ ] "Clear" button clears selection and fits view

### Focus Behavior
- [ ] "Focus Primary Hub" selects hub, sets it as anchor, enables focus, and fits
- [ ] Focus pill shows correct hop count and anchor name
- [ ] Clicking × on focus pill exits focus mode
- [ ] "Focus Around This Node" enables focus if not already enabled
- [ ] Changing selection does not change focus anchor

### View Controls
- [ ] "Fit" zooms to fit all visible nodes (respects focus filter)
- [ ] "Reset" resets pan/zoom without affecting selection or focus
- [ ] Neither control is triggered by selection changes

### Hub Metrics
- [ ] Selecting "Bridges" metric shows visible nodes (not empty graph)
- [ ] If no neighbors found, shows "No neighbors found" message
- [ ] All three metrics produce valid hub selections

### Export
- [ ] "Export Summary" copies text to clipboard
- [ ] Toast/feedback confirms the copy action

### Tooltips
- [ ] Every button in toolbar has a tooltip
- [ ] Every metric in sidebar has a tooltip
- [ ] All tooltips are accurate to actual behavior
