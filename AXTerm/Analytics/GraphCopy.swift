//
//  GraphCopy.swift
//  AXTerm
//
//  Centralized UI strings for tooltips, labels, and accessibility text.
//  All copy follows Apple Human Interface Guidelines: concise, neutral, action-oriented.
//

import Foundation

// MARK: - Graph View Controls

nonisolated enum GraphCopy {

    // MARK: Toolbar Actions

    enum Toolbar {
        // Fit: Zooms to show all visible nodes at optimal size
        static let fitToNodesLabel = "Fit"
        static let fitToNodesTooltip = "Zoom to fit all visible nodes. Adjusts zoom level to show the entire graph."
        static let fitToNodesAccessibility = "Fit all visible nodes in view"

        // Reset: Returns to the default 1:1 zoom and centered position
        static let resetViewLabel = "Home"
        static let resetViewTooltip = "Return to default zoom (1:1) and center position."
        static let resetViewAccessibility = "Reset to default view"

        static let clearSelectionLabel = "Clear"
        static let clearSelectionTooltip = "Deselect all nodes."
        static let clearSelectionAccessibility = "Clear node selection"

        static let noNodesToFit = "No nodes to fit."
    }

    // MARK: Focus Mode

    enum Focus {
        static let focusPillTooltipTemplate = "Showing %d-hop neighborhood of %@. Click to adjust."
        static let focusPillAccessibilityTemplate = "Focus mode active, showing %d hops from %@"

        static let clearFocusLabel = "Exit Focus"
        static let clearFocusTooltip = "Exit focus mode and show all nodes."
        static let clearFocusAccessibility = "Exit focus mode"

        static let setAsAnchorLabel = "Focus Around This Node"
        static let setAsAnchorTooltip = "Filter the graph to show only nodes within the specified hop distance of this station. Enables focus mode if not already active."
        static let setAsAnchorAccessibility = "Set this node as focus anchor"
        static let focusSelectionLabel = "Focus Around Selection"
        static let focusSelectionTooltip = "Keep the current selection and zoom to the selected stations' extents."
        static let focusSelectionAccessibility = "Focus around selected stations"

        static let hopCountLabel = "Hop Distance"
        static let hopCountTooltip = "Number of connection steps from the anchor node to include. Higher values show more of the network."

        static let useSelectedAsAnchorLabel = "Use Selected as Anchor"
        static let useSelectedAsAnchorTooltip = "Set the currently selected node as the focus anchor."
    }

    // MARK: Selection

    enum Selection {
        static func countLabel(_ count: Int) -> String {
            count == 1 ? "1 node selected" : "\(count) nodes selected"
        }

        static let clearButtonTooltip = "Deselect all nodes and fit view to all visible nodes."
        static let clearButtonAccessibility = "Clear selection"

        static let nodeChipClearTooltip = "Deselect this node."
    }

    // MARK: Hub Metrics

    enum HubMetric {
        static let pickerLabel = "Hub Metric"
        static let pickerTooltip = "Choose how to identify the primary hub node."

        static let degreeLabel = "Degree"
        static let degreeDescription = "Most direct connections"
        static let degreeTooltip = "Select the node with the most direct connections to other stations."

        static let trafficLabel = "Traffic"
        static let trafficDescription = "Most packets"
        static let trafficTooltip = "Select the node that has sent or received the most packets."

        static let bridgesLabel = "Bridges"
        static let bridgesDescription = "Network bridges"
        static let bridgesTooltip = "Select nodes that connect otherwise separate parts of the network (high betweenness centrality)."

        static let noNeighborsFound = "No neighbors found with current filters."
    }

    // MARK: Quick Actions

    enum QuickActions {
        static let focusPrimaryHubLabel = "Focus Primary Hub"
        static let focusPrimaryHubTooltip = "Select and focus on the most connected node based on the current hub metric."
        static let focusPrimaryHubAccessibility = "Focus on primary hub node"

        static let showActiveNodesLabel = "Show Active (10m)"
        static let showActiveNodesTooltip = "Select all stations that have sent or received packets in the last 10 minutes."
        static let showActiveNodesAccessibility = "Select recently active stations"

        static let exportSummaryLabel = "Export Summary"
        static let exportSummaryTooltip = "Copy a text summary of network health metrics to the clipboard."
        static let exportSummaryAccessibility = "Copy network summary to clipboard"
        static let exportSuccessMessage = "Summary copied to clipboard."
        static let exportNotAvailable = "Export not available yet."
    }

    // MARK: Network Health Metrics

    enum Health {
        // Header / overall score
        static let headerLabel = "Network Health"
        static let headerTooltip = "Composite score combining network topology (selected timeframe) and recent activity (last 10 minutes). View filters (Min Edge, Max Nodes) don't affect this score."
        static let overallScoreTooltip = "Composite health score (0–100). Formula: 60% topology + 40% activity. Uses a canonical graph (minEdge=2) that ignores view filters."
        static let scoreExperimentalNote = "View filters don't affect health: Min/Max edge filters only change what's drawn in the graph."

        // MARK: Topology Metrics (timeframe-dependent, canonical graph)
        // These metrics use a canonical graph with minEdge=2, ignoring view filters

        static let stationsHeardLabel = "Stations"
        static func stationsHeardLabelWithTimeframe(_ tf: String) -> String {
            tf.isEmpty ? "Stations Heard" : "Stations (\(tf))"
        }
        static func stationsHeardTooltip(_ tf: String) -> String {
            "Unique stations in the canonical health graph during the \(tf.isEmpty ? "selected timeframe" : tf) window. Uses minEdge=2, ignoring view filters."
        }

        static let totalPacketsLabel = "Packets"
        static func totalPacketsLabelWithTimeframe(_ tf: String) -> String {
            tf.isEmpty ? "Total Packets" : "Packets (\(tf))"
        }
        static func totalPacketsTooltip(_ tf: String) -> String {
            "Total AX.25 frames received during the \(tf.isEmpty ? "selected timeframe" : tf) window."
        }

        static let mainClusterLabel = "Main Cluster"
        static func mainClusterLabelWithTimeframe(_ tf: String) -> String {
            tf.isEmpty ? "Main Cluster" : "Cluster (\(tf))"
        }
        static func mainClusterTooltip(_ tf: String) -> String {
            "C1: Percentage of stations in the largest connected group during the \(tf.isEmpty ? "selected timeframe" : tf) window. Computed from canonical graph (minEdge=2). Higher values indicate a well-connected network."
        }

        static let connectivityRatioLabel = "Connectivity"
        static func connectivityRatioLabelWithTimeframe(_ tf: String) -> String {
            tf.isEmpty ? "Connectivity" : "Connect (\(tf))"
        }
        static func connectivityRatioTooltip(_ tf: String) -> String {
            "C2: Percentage of possible links that exist in the canonical graph. Formula: actualEdges / possibleEdges × 100. Based on \(tf.isEmpty ? "selected timeframe" : tf)."
        }

        static let isolationReductionLabel = "Isolation"
        static func isolationReductionLabelWithTimeframe(_ tf: String) -> String {
            tf.isEmpty ? "Isolation" : "Isolation (\(tf))"
        }
        static func isolationReductionTooltip(_ tf: String) -> String {
            "C3: Higher is better. 100 means no isolated stations. Formula: 100 - (% isolated nodes). Based on canonical graph during \(tf.isEmpty ? "selected timeframe" : tf)."
        }

        static let topRelayShareLabel = "Top Relay"
        static func topRelayShareLabelWithTimeframe(_ tf: String) -> String {
            tf.isEmpty ? "Top Relay" : "Relay (\(tf))"
        }
        static func topRelayShareTooltip(_ tf: String) -> String {
            "Share of connections involving the busiest relay during the \(tf.isEmpty ? "selected timeframe" : tf) window. Lower values indicate better redundancy."
        }

        // MARK: Activity Metrics (fixed 10-minute window)

        static let activeStationsLabel = "Active (10m)"
        static let activeStationsTooltip = "A1: Percentage of stations heard in the last 10 minutes. Independent of selected timeframe. Used in activity score."

        static let packetRateLabel = "Rate (10m)"
        static let packetRateTooltip = "A2: Packets per minute over the last 10 minutes, EMA-smoothed for stability. Normalized to ideal rate of 1.0 pkt/min. Independent of selected timeframe."

        // MARK: Other

        static let activityChartLabel = "Activity (1 hour)"
        static let activityChartTooltip = "Packet activity over the last 60 minutes, in 5-minute intervals."

        static let freshnessLabel = "Freshness"
        static let freshnessTooltip = "Ratio of recently active stations (10m) to total stations in the selected timeframe."

        static let isolatedNodesLabel = "Isolated"
        static let isolatedNodesTooltip = "Stations with no observed connections in the canonical health graph (minEdge=2). View filters don't affect this count."
    }

    // MARK: Score Breakdown

    enum ScoreBreakdown {
        static let headerLabel = "Score Breakdown"
        static let headerTooltip = "Composite score formula: 60% topology + 40% activity. Uses canonical graph (minEdge=2) that ignores view filters."

        // Topology metrics (timeframe-dependent) - 60% total
        static let topologyLabel = "Topology (TF)"
        static let topologyTooltip = "60% of final score. Formula: 0.5×C1 + 0.3×C2 + 0.2×C3. Based on selected timeframe using canonical graph."

        static let c1MainClusterLabel = "C1: Main Cluster"
        static let c1MainClusterTooltip = "Percentage of nodes in the largest connected component. Weight: 50% of topology score (30% of final)."

        static let c2ConnectivityLabel = "C2: Connectivity"
        static let c2ConnectivityTooltip = "Percentage of possible edges that exist. Formula: actualEdges / possibleEdges × 100. Weight: 30% of topology score (18% of final)."

        static let c3IsolationLabel = "C3: Isolation Reduction"
        static let c3IsolationTooltip = "100 minus percentage of isolated nodes. Higher is better. Weight: 20% of topology score (12% of final)."

        // Activity metrics (10-minute window) - 40% total
        static let activityLabel = "Activity (10m)"
        static let activityTooltip = "40% of final score. Formula: 0.6×A1 + 0.4×A2. Based on last 10 minutes regardless of timeframe."

        static let a1ActiveNodesLabel = "A1: Active Nodes"
        static let a1ActiveNodesTooltip = "Percentage of stations heard in last 10 minutes. Weight: 60% of activity score (24% of final)."

        static let a2PacketRateLabel = "A2: Packet Rate"
        static let a2PacketRateTooltip = "Normalized packet rate (ideal = 1.0 pkt/min). EMA-smoothed. Weight: 40% of activity score (16% of final)."

        // Legacy labels for backward compatibility
        static let connectivityLabel = "Connectivity"
        static let connectivityTooltip = "Based on the size of the largest connected cluster in the selected timeframe."

        static let redundancyLabel = "Redundancy"
        static let redundancyTooltip = "Lower relay concentration means better path diversity. Based on selected timeframe."

        static let stabilityLabel = "Stability"
        static let stabilityTooltip = "Based on packets per station ratio during the selected timeframe."

        static let freshnessLabel = "Freshness (10m)"
        static let freshnessTooltip = "Ratio of stations active in the last 10 minutes to total stations in the timeframe."
    }

    // MARK: Warnings

    enum Warnings {
        static let singleRelayDominance = "Single relay dominance"
        static let singleRelayDominanceDetail = "Over 60% of traffic flows through one station."

        static let staleNodes = "Stale stations"
        static let staleNodesDetail = "Many stations haven't been heard recently."

        static let fragmentedNetwork = "Fragmented network"
        static let fragmentedNetworkDetail = "Less than half of stations are in the main cluster."

        static let isolatedNodes = "Isolated stations"
        static let isolatedNodesDetail = "Some stations have no observed connections."

        static let lowActivity = "Low activity"
        static let lowActivityDetail = "Packet rate is below 0.1 per minute."
    }

    // MARK: Graph View Modes

    enum ViewMode {
        static let pickerLabel = "View"
        static let pickerTooltip = "Changes which link types are shown in the network graph. Does not affect Network Health."

        static let connectivityLabel = "Connectivity"
        static let connectivityDescription = "Direct connections"
        static let connectivityTooltip = "Visualize direct RF connections. High-fidelity map of stations you can reach without digipeaters. Best for antenna testing and propagation analysis."

        static let routingLabel = "Routing"
        static let routingDescription = "Packet flow paths"
        static let routingTooltip = "Visualize the multi-hop network. Show how packets are digipeated and which nodes act as relays. Best for understanding regional coverage and packet flow."

        static let allLabel = "All"
        static let allDescription = "Everything"
        static let allTooltip = "Complete AX.25 topology view. Combines direct connections with digipeated paths for a full view of all observed station interactions."

        static let netromClassicLabel = "NET/ROM (Classic)"
        static let netromClassicDescription = "NET/ROM broadcast routes"
        static let netromClassicTooltip = "Official NET/ROM network map. Combines 'NODES' broadcasts for multi-hop routes with direct AX.25 neighbors for local topology. Best for backbone analysis."

        static let netromInferredLabel = "NET/ROM (Inferred)"
        static let netromInferredDescription = "NET/ROM inferred routes"
        static let netromInferredTooltip = "Passive NET/ROM discovery map. Reveals neighbors and routes detected from live L3/L4 traffic, showing paths that are active but not broadcasted."

        static let netromHybridLabel = "NET/ROM (Hybrid)"
        static let netromHybridDescription = "NET/ROM combined routes"
        static let netromHybridTooltip = "Comprehensive NET/ROM view merging official broadcasts with live traffic discovery for the most accurate and up-to-date routing map."
    }

    // MARK: Link Types (for legend and tooltips)

    enum LinkType {
        static let directPeerLabel = "Direct Peer"
        static let directPeerTooltip = "Endpoint-to-endpoint traffic involving this station within the selected timeframe. Excludes digipeater-only paths. Solid line."

        static let heardDirectLabel = "Heard Direct"
        static let heardDirectTooltip = "Frames decoded directly from this station (no digipeaters in the path). Indicates likely RF reachability. Dotted line."

        static let heardViaLabel = "Heard Via"
        static let heardViaTooltip = "Frames observed via digipeaters. Shows network visibility, not direct RF reachability. Dashed line."

        static let infrastructureLabel = "Infrastructure"
        static let infrastructureTooltip = "BEACON, ID, or BBS traffic. Not counted as peer connections."

        static let legendTitle = "Connection Types"
        static let legendTooltip = "Different line styles indicate how stations are connected."
    }

    // MARK: Inspector

    enum Inspector {
        static let tabLabel = "Inspector"
        static let overviewTabLabel = "Overview"

        static let noSelectionTitle = "No Selection"
        static let noSelectionMessage = "Select a node in the graph to see details."

        static let packetsInLabel = "Packets In"
        static let packetsInTooltip = "Number of packets received by this station."

        static let packetsOutLabel = "Packets Out"
        static let packetsOutTooltip = "Number of packets sent by this station."

        static let bytesInLabel = "Bytes In"
        static let bytesInTooltip = "Total payload bytes received."

        static let bytesOutLabel = "Bytes Out"
        static let bytesOutTooltip = "Total payload bytes sent."

        static let degreeLabel = "Connections"
        static let degreeTooltip = "Number of unique stations this node has communicated with."

        static let neighborsLabel = "Top Neighbors"
        static let neighborsTooltip = "Stations most frequently in contact with this node."

        static let ssidBadgeTooltipTemplate = "%d SSIDs observed for this base callsign."

        // Relationship sections
        static let directPeersSection = "Direct Peers"
        static let directPeersSectionTooltip = "Stations you've exchanged packets with directly (endpoint-to-endpoint). True bidirectional communication."

        static let heardDirectSection = "Heard Direct"
        static let heardDirectSectionTooltip = "Stations you've decoded directly without digipeaters. A direct RF connection is plausible."

        static let heardViaSection = "Heard Via"
        static let heardViaSectionTooltip = "Stations observed through digipeaters. Reachable on the network, but not proof of direct RF reception."

        static let viaDigipeaterTemplate = "via %@"
        static let lastHeardTemplate = "Last: %@"

        // Multi-selection inspector
        static let multiSelectionTitle = "Stations Selected"
        static let multiSelectionListTooltip = "Stations currently included in this selection."

        static let internalLinksLabel = "Links Within Selection"
        static let internalLinksTooltip = "Observed links between selected stations. Format: observed links / possible links."

        static let selectionDensityLabel = "Selection Density"
        static let selectionDensityTooltip = "How tightly connected the selected stations are."

        static let packetsWithinSelectionLabel = "Packets Within Selection"
        static let packetsWithinSelectionTooltip = "Total packets exchanged where both endpoints are selected stations."

        static let bytesWithinSelectionLabel = "Bytes Within Selection"
        static let bytesWithinSelectionTooltip = "Total payload bytes exchanged where both endpoints are selected stations."

        static let sharedExternalRelaysLabel = "Shared External Relays"
        static let sharedExternalRelaysTooltip = "Stations outside the selection that connect to two or more selected stations."

        static let interactionTypesHeader = "Interaction Types"
        static let interactionTypesTooltip = "Breakdown of within-selection links by relationship type."

        static let withinSelectionHeader = "Within Selection"
        static let withinSelectionTooltip = "Links where both endpoints are selected stations."

        static let sharedConnectionsHeader = "Shared Connections"
        static let sharedConnectionsTooltip = "Outside stations that connect to multiple selected stations."

        static let selectedStationsHeader = "Selected Stations"
        static let selectedStationsTooltip = "Per-station summary for each selected station."

        static let selectedStationRowTooltipTemplate = "Packets in: %d, packets out: %d, unique connections: %d."
        static let sharedConnectionRowTooltipTemplate = "Connected to %d selected stations with %d packets."
        static let internalLinkRowTooltipTemplate = "Packets: %d, bytes: %d."
    }

    // MARK: Station Identity Mode

    enum StationIdentity {
        static let pickerLabel = "Identity"
        static let pickerTooltip = "Groups stations by base callsign or displays each SSID separately."

        static let stationLabel = "Group by Station"
        static let stationShortLabel = "Station"
        static let stationDescription = "Combine SSIDs"
        static let stationTooltip = "Group all SSIDs under one station node. ANH, ANH-1, and ANH-15 appear as a single \"ANH\" node."

        static let ssidLabel = "Split by SSID"
        static let ssidShortLabel = "SSID"
        static let ssidDescription = "Separate nodes"
        static let ssidTooltip = "Show each SSID as a separate node. ANH and ANH-15 appear as distinct nodes."

        static let groupedBadgeTooltipTemplate = "%d SSIDs grouped under this station: %@"
        static let inspectorGroupedHeader = "Grouped SSIDs"
        static let inspectorGroupedTooltip = "All SSID variants observed for this station during the selected timeframe."
    }

    // MARK: Graph Controls (Network Graph Card Header)

    enum GraphControls {
        static let includeViaLabel = "Include via digipeaters"
        static let includeViaTooltip = "Shows links observed through digipeater paths in Routing/All views."

        static let minEdgeCountLabel = "Min edge"
        static let minEdgeCountTooltip = "Minimum packets required to display a connection in the graph (view only)."

        static let maxNodesLabel = "Max"
        static let maxNodesTooltip = "Limits visible nodes to keep the graph readable (view only)."
    }

    // MARK: Sidebar Tabs

    enum Sidebar {
        static let overviewTab = "Overview"
        static let inspectorTab = "Inspector"
    }

    // MARK: Accessibility

    enum Accessibility {
        static let graphRegion = "Network graph visualization"
        static let sidebarRegion = "Graph sidebar with metrics and inspector"
        static let toolbarRegion = "Graph toolbar with view controls"
    }
}
