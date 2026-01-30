//
//  GraphCopy.swift
//  AXTerm
//
//  Centralized UI strings for tooltips, labels, and accessibility text.
//  All copy follows Apple Human Interface Guidelines: concise, neutral, action-oriented.
//

import Foundation

// MARK: - Graph View Controls

enum GraphCopy {

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
        static let headerTooltip = "Summary of network connectivity (based on selected timeframe) and current activity (last 10 minutes)."
        static let overallScoreTooltip = "Composite health score (0–100). 60% topology (selected timeframe) + 40% activity (last 10 minutes). Higher is better."
        static let scoreExperimentalNote = "This score combines historical structure and current activity."

        // MARK: Topology Metrics (timeframe-dependent)
        // These labels include a placeholder for the timeframe suffix

        static let stationsHeardLabel = "Stations"
        static func stationsHeardLabelWithTimeframe(_ tf: String) -> String {
            tf.isEmpty ? "Stations Heard" : "Stations (\(tf))"
        }
        static func stationsHeardTooltip(_ tf: String) -> String {
            "Unique stations observed during the \(tf.isEmpty ? "selected timeframe" : tf) window."
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
            "Percentage of stations in the largest connected group during the \(tf.isEmpty ? "selected timeframe" : tf) window. Higher values indicate a well-connected network."
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
        static let activeStationsTooltip = "Stations that have sent or received at least one packet in the last 10 minutes. Independent of selected timeframe."

        static let packetRateLabel = "Rate (10m)"
        static let packetRateTooltip = "Packets per minute over the last 10 minutes. Independent of selected timeframe."

        // MARK: Other

        static let activityChartLabel = "Activity (1 hour)"
        static let activityChartTooltip = "Packet activity over the last 60 minutes, in 5-minute intervals."

        static let freshnessLabel = "Freshness"
        static let freshnessTooltip = "Ratio of recently active stations (10m) to total stations in the selected timeframe."

        static let isolatedNodesLabel = "Isolated"
        static let isolatedNodesTooltip = "Stations with no observed connections during the selected timeframe."
    }

    // MARK: Score Breakdown

    enum ScoreBreakdown {
        static let headerLabel = "Score Breakdown"
        static let headerTooltip = "Health score components: 60% topology (selected timeframe) + 40% activity (last 10 minutes)."

        // Activity metrics (10-minute window) - 40% total
        static let activityLabel = "Activity (10m)"
        static let activityTooltip = "Based on packet rate over the last 10 minutes. Higher traffic indicates an active network."

        static let freshnessLabel = "Freshness (10m)"
        static let freshnessTooltip = "Ratio of stations active in the last 10 minutes to total stations in the timeframe."

        // Topology metrics (timeframe-dependent) - 60% total
        static let connectivityLabel = "Connectivity"
        static let connectivityTooltip = "Based on the size of the largest connected cluster in the selected timeframe."

        static let redundancyLabel = "Redundancy"
        static let redundancyTooltip = "Lower relay concentration means better path diversity. Based on selected timeframe."

        static let stabilityLabel = "Stability"
        static let stabilityTooltip = "Based on packets per station ratio during the selected timeframe."
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
