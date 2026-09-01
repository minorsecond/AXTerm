//
//  AnalyticsGraphMetalView.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-20.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import MetalKit
import SwiftUI

struct AnalyticsGraphView: View {
    let graphModel: GraphModel
    /// In NET/ROM source modes node weight is a route count, not a packet count;
    /// the hover tooltip must not label it "Packets".
    var isNetRomSource: Bool = false
    /// Node identity keys of the path being drawn (origin first); empty when not drafting.
    var pathDraftChain: [String] = []
    let nodePositions: [NodePosition]
    let selectedNodeIDs: Set<String>
    let hoveredNodeID: String?
    let myCallsign: String
    let resetToken: UUID
    let focusNodeID: String?
    let fitToSelectionRequest: UUID?
    let fitTargetNodeIDs: Set<String>
    let resetCameraRequest: UUID?
    /// Focus neighborhood IDs. Empty means no focus emphasis.
    let visibleNodeIDs: Set<String>
    let onSelect: (String, Bool) -> Void
    let onSelectMany: (Set<String>, Bool) -> Void
    let onClearSelection: () -> Void
    let onHover: (String?) -> Void
    let onFocusHandled: () -> Void
    let isServiceEndpointIgnored: (String) -> Bool
    let isServiceEndpointSimulated: (String) -> Bool
    let onAddServiceEndpointIgnore: (String) -> Void
    let onRemoveServiceEndpointIgnore: (String) -> Void
    let onSimulateServiceEndpointIgnore: (String) -> Void
    let onApplySimulatedServiceEndpointIgnore: (String) -> Void
    let onCancelSimulatedServiceEndpointIgnore: (String) -> Void
    var onDrawPathTo: (String) -> Void = { _ in }
    /// Node menu raised by a long press, where the platform cannot raise one
    /// itself. macOS gets an NSMenu from the view and never sets this.
    @State private var touchMenu: TouchGraphMenu?

    @State private var selectionRect: CGRect?
    @State private var hoverPoint: CGPoint?
    @State private var hoverNodeID: String?
    @State private var cameraState: CameraState = CameraState(scale: 1, offset: .zero)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GraphMetalViewRepresentable(
                    graphModel: graphModel,
                    nodePositions: nodePositions,
                    selectedNodeIDs: selectedNodeIDs,
                    hoveredNodeID: hoveredNodeID,
                    myCallsign: myCallsign,
                    resetToken: resetToken,
                    focusNodeID: focusNodeID,
                    fitToSelectionRequest: fitToSelectionRequest,
                    fitTargetNodeIDs: fitTargetNodeIDs,
                    resetCameraRequest: resetCameraRequest,
                    visibleNodeIDs: visibleNodeIDs,
                    onSelect: onSelect,
                    onSelectMany: onSelectMany,
                    onClearSelection: onClearSelection,
                    onHover: { nodeID, position in
                        DispatchQueue.main.async {
                            hoverNodeID = nodeID
                            hoverPoint = position
                        }
                        onHover(nodeID)
                    },
                    onSelectionRect: { rect in
                        DispatchQueue.main.async {
                            selectionRect = rect
                        }
                    },
                    onFocusHandled: onFocusHandled,
                    isServiceEndpointIgnored: isServiceEndpointIgnored,
                    isServiceEndpointSimulated: isServiceEndpointSimulated,
                    onAddServiceEndpointIgnore: onAddServiceEndpointIgnore,
                    onRemoveServiceEndpointIgnore: onRemoveServiceEndpointIgnore,
                    onSimulateServiceEndpointIgnore: onSimulateServiceEndpointIgnore,
                    onApplySimulatedServiceEndpointIgnore: onApplySimulatedServiceEndpointIgnore,
                    onCancelSimulatedServiceEndpointIgnore: onCancelSimulatedServiceEndpointIgnore,
                    onCameraUpdate: { newState in
                        DispatchQueue.main.async {
                            cameraState = newState
                        }
                    },
                    onDrawPathTo: onDrawPathTo,
                    onContextMenu: { menu, location in
                        touchMenu = TouchGraphMenu(menu: menu, location: location)
                    }
                )
                // A long press is the touch equivalent of a right-click, and
                // the actions are the same ones the Mac shows.
                .popover(item: $touchMenu, attachmentAnchor: .point(.center)) { item in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.menu.callsign)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                        GraphContextMenuButtons(menu: item.menu)
                            .buttonStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                    }
                    .padding(.bottom, 8)
                    .presentationCompactAdaptation(.popover)
                }

                if let selectionRect {
                    let h = geometry.size.height
                    let flipped = CGRect(x: selectionRect.minX, y: h - selectionRect.maxY, width: selectionRect.width, height: selectionRect.height)
                    SelectionRectView(rect: flipped)
                }

                // Drawn connect path overlay
                if pathDraftChain.count > 1 {
                    PathDraftOverlay(
                        chain: pathDraftChain,
                        nodePositions: nodePositions,
                        cameraState: cameraState,
                        viewSize: geometry.size
                    )
                    .allowsHitTesting(false)
                }

                // Node labels overlay
                NodeLabelsOverlay(
                    graphModel: graphModel,
                    nodePositions: nodePositions,
                    selectedNodeIDs: selectedNodeIDs,
                    hoveredNodeID: hoveredNodeID,
                    myCallsign: myCallsign,
                    cameraState: cameraState,
                    viewSize: geometry.size,
                    visibleNodeIDs: visibleNodeIDs
                )
                .allowsHitTesting(false)

                if let hoverNodeID,
                   let node = graphModel.nodes.first(where: { $0.id == hoverNodeID }),
                   let nodePos = nodePositions.first(where: { $0.id == hoverNodeID }) {
                    let tooltipPosition = Self.calculateTooltipPosition(
                        nodePos: nodePos,
                        allPositions: nodePositions,
                        viewSize: geometry.size,
                        cameraState: cameraState
                    )
                    GraphTooltipView(node: node, isNetRomSource: isNetRomSource)
                        .position(tooltipPosition)
                }
            }
        }
        .background(AnalyticsStyle.Colors.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius))
        .focusable(interactions: [])  // Disable focus-driven scrolling but keep keyboard handling via NSView
        // Escape clears the selection where there is an Escape key. On touch,
        // tapping empty graph space already does it.
        #if os(macOS)
        .onExitCommand {
            onClearSelection()
        }
        #endif
    }

    /// Calculates the optimal tooltip position near a node, avoiding edges and other nodes.
    /// Uses the same coordinate transformation as normalizedToScreen for accurate placement.
    /// Tries all four quadrants and picks the one with fewest obstructions.
    private static func calculateTooltipPosition(
        nodePos: NodePosition,
        allPositions: [NodePosition],
        viewSize: CGSize,
        cameraState: CameraState
    ) -> CGPoint {
        let inset = AnalyticsStyle.Layout.graphInset
        let width = max(1, viewSize.width - inset * 2)
        let height = max(1, viewSize.height - inset * 2)

        // Helper to convert normalized position to screen coordinates
        func toScreen(_ pos: NodePosition) -> CGPoint {
            let base = CGPoint(
                x: inset + pos.x * width,
                y: inset + pos.y * height
            )
            let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            return CGPoint(
                x: (base.x - center.x) * cameraState.scale + center.x + cameraState.offset.width,
                y: (base.y - center.y) * cameraState.scale + center.y + cameraState.offset.height
            )
        }

        let nodeScreen = toScreen(nodePos)

        // Tooltip sizing - keep compact
        let tooltipWidth: CGFloat = 100
        let tooltipHeight: CGFloat = 55

        // Offset from node center
        let nodeOffset: CGFloat = 12 * cameraState.scale
        let margin: CGFloat = 6

        // Get screen positions of nearby nodes (within reasonable distance)
        let maxCheckDistance: CGFloat = 150
        let otherNodeScreens: [CGPoint] = allPositions
            .filter { $0.id != nodePos.id }
            .map { toScreen($0) }
            .filter { pt in
                let dx = pt.x - nodeScreen.x
                let dy = pt.y - nodeScreen.y
                return sqrt(dx * dx + dy * dy) < maxCheckDistance
            }

        // Define the four candidate positions (quadrants)
        struct Candidate {
            let x: CGFloat
            let y: CGFloat
            let edgePenalty: CGFloat  // How much it clips edges
            let nodePenalty: Int      // How many nodes it overlaps
        }

        // Calculate candidate positions for each quadrant
        let candidates: [(CGFloat, CGFloat)] = [
            (nodeScreen.x + nodeOffset + tooltipWidth / 2, nodeScreen.y - nodeOffset - tooltipHeight / 2),  // Top-right
            (nodeScreen.x - nodeOffset - tooltipWidth / 2, nodeScreen.y - nodeOffset - tooltipHeight / 2),  // Top-left
            (nodeScreen.x + nodeOffset + tooltipWidth / 2, nodeScreen.y + nodeOffset + tooltipHeight / 2),  // Bottom-right
            (nodeScreen.x - nodeOffset - tooltipWidth / 2, nodeScreen.y + nodeOffset + tooltipHeight / 2),  // Bottom-left
        ]

        // Score each candidate
        var bestCandidate: (x: CGFloat, y: CGFloat) = candidates[0]
        var bestScore: CGFloat = .infinity

        for (candidateX, candidateY) in candidates {
            // Calculate edge penalty (how much tooltip would be clipped)
            var edgePenalty: CGFloat = 0
            let left = candidateX - tooltipWidth / 2
            let right = candidateX + tooltipWidth / 2
            let top = candidateY - tooltipHeight / 2
            let bottom = candidateY + tooltipHeight / 2

            if left < margin { edgePenalty += margin - left }
            if right > viewSize.width - margin { edgePenalty += right - (viewSize.width - margin) }
            if top < margin { edgePenalty += margin - top }
            if bottom > viewSize.height - margin { edgePenalty += bottom - (viewSize.height - margin) }

            // Calculate node overlap penalty
            let tooltipRect = CGRect(
                x: candidateX - tooltipWidth / 2,
                y: candidateY - tooltipHeight / 2,
                width: tooltipWidth,
                height: tooltipHeight
            )

            var nodePenalty: CGFloat = 0
            let nodeRadius: CGFloat = 12 * cameraState.scale  // Approximate node visual radius
            for otherScreen in otherNodeScreens {
                // Check if node center is inside or very close to tooltip rect
                let expandedRect = tooltipRect.insetBy(dx: -nodeRadius, dy: -nodeRadius)
                if expandedRect.contains(otherScreen) {
                    // Weight by how centered the node is in the tooltip (worse if dead center)
                    let dx = abs(otherScreen.x - candidateX)
                    let dy = abs(otherScreen.y - candidateY)
                    let centeredness = 1.0 - (dx + dy) / (tooltipWidth + tooltipHeight)
                    nodePenalty += 50 * centeredness  // High penalty for overlapping nodes
                }
            }

            // Combined score (lower is better)
            // Edge penalty is weighted higher since clipping looks worse than covering a node
            let score = edgePenalty * 2 + nodePenalty

            if score < bestScore {
                bestScore = score
                bestCandidate = (candidateX, candidateY)
            }
        }

        // Final clamping to ensure tooltip stays fully visible
        let finalX = max(tooltipWidth / 2 + margin, min(bestCandidate.x, viewSize.width - tooltipWidth / 2 - margin))
        let finalY = max(tooltipHeight / 2 + margin, min(bestCandidate.y, viewSize.height - tooltipHeight / 2 - margin))

        return CGPoint(x: finalX, y: finalY)
    }
}

/// Lightweight state for camera position used by label overlay.
nonisolated struct CameraState: Equatable {
    var scale: CGFloat
    var offset: CGSize
}

/// Renders the path being drawn: an accent polyline through the clicked
/// stations with numbered hop markers.
private struct PathDraftOverlay: View {
    let chain: [String]
    let nodePositions: [NodePosition]
    let cameraState: CameraState
    let viewSize: CGSize

    var body: some View {
        Canvas { context, size in
            let positionMap = Dictionary(uniqueKeysWithValues: nodePositions.map { ($0.id, $0) })
            let inset = AnalyticsStyle.Layout.graphInset

            let screenPoints: [CGPoint] = chain.compactMap { key in
                guard let position = positionMap[key] else { return nil }
                return normalizedToScreen(
                    normalized: CGPoint(x: position.x, y: position.y),
                    viewSize: size,
                    inset: inset,
                    scale: cameraState.scale,
                    offset: cameraState.offset
                )
            }
            guard screenPoints.count > 1 else { return }

            var path = Path()
            path.move(to: screenPoints[0])
            for point in screenPoints.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(
                path,
                with: .color(Color.accentColor.opacity(0.85)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [6, 4])
            )

            for (index, point) in screenPoints.enumerated() {
                let radius: CGFloat = 9
                let circleRect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Circle().path(in: circleRect), with: .color(Color.accentColor))
                context.draw(
                    Text(index == 0 ? "MY" : "\(index)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white),
                    at: point
                )
            }
        }
    }

    // Same camera transform as NodeLabelsOverlay / the Metal renderer.
    private func normalizedToScreen(
        normalized: CGPoint,
        viewSize: CGSize,
        inset: CGFloat,
        scale: CGFloat,
        offset: CGSize
    ) -> CGPoint {
        let width = max(1, viewSize.width - inset * 2)
        let height = max(1, viewSize.height - inset * 2)
        let base = CGPoint(
            x: inset + normalized.x * width,
            y: inset + normalized.y * height
        )
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        return CGPoint(
            x: (base.x - center.x) * scale + center.x + offset.width,
            y: (base.y - center.y) * scale + center.y + offset.height
        )
    }
}

/// Overlay that renders callsign suffix labels near nodes.
private struct NodeLabelsOverlay: View {
    let graphModel: GraphModel
    let nodePositions: [NodePosition]
    let selectedNodeIDs: Set<String>
    let hoveredNodeID: String?
    let myCallsign: String
    let cameraState: CameraState
    let viewSize: CGSize
    /// Focus neighborhood IDs. Empty means no focus emphasis.
    let visibleNodeIDs: Set<String>

    private let minZoomForLabels: CGFloat = 0.6
    private let maxLabelsAtLowZoom: Int = 12
    /// Small gap between node edge and label
    private let labelGap: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            guard cameraState.scale >= minZoomForLabels else { return }

            let normalizedCallsign = CallsignMatcher.normalize(myCallsign)
            let positionMap = Dictionary(uniqueKeysWithValues: nodePositions.map { ($0.id, $0) })
            let inset = AnalyticsStyle.Layout.graphInset

            let displayNodes = graphModel.nodes

            // Compute node weight range for radius calculation
            let weights = displayNodes.map { $0.weight }
            let minWeight = weights.min() ?? 1
            let maxWeight = weights.max() ?? 1

            // Sort nodes by priority for label display
            let sortedNodes = displayNodes.sorted { lhs, rhs in
                labelPriority(for: lhs) > labelPriority(for: rhs)
            }

            // Determine max labels based on zoom
            let zoomProgress = min(1, (cameraState.scale - minZoomForLabels) / 0.6)
            let maxLabels = maxLabelsAtLowZoom + Int(CGFloat(displayNodes.count - maxLabelsAtLowZoom) * zoomProgress)

            var drawnRects: [CGRect] = []

            // Always the full callsign. Suffix labels ("TST", "PI") once saved
            // space when zoomed out, but a station you cannot name is a station
            // you cannot act on — and clutter is already handled below by
            // dropping any label that would collide with one already drawn, so
            // abbreviating bought nothing but confusion (rig review 2026-08-29).
            for node in sortedNodes.prefix(maxLabels) {
                guard let position = positionMap[node.id] else { continue }
                guard CallsignValidator.isValidRoutingNode(node.callsign) else { continue }

                let labelText = node.callsign

                // Calculate screen position
                let screenPos = normalizedToScreen(
                    normalized: CGPoint(x: position.x, y: position.y),
                    viewSize: size,
                    inset: inset,
                    scale: cameraState.scale,
                    offset: cameraState.offset
                )

                // Skip if off-screen
                guard screenPos.x > 0 && screenPos.x < size.width &&
                      screenPos.y > 0 && screenPos.y < size.height else { continue }

                // Calculate node radius based on weight (same formula as Metal renderer)
                let nodeRadius = calculateNodeRadius(weight: node.weight, minWeight: minWeight, maxWeight: maxWeight)
                let scaledRadius = nodeRadius * cameraState.scale

                // Calculate label position (to the right of node, accounting for node radius)
                let labelOffset = scaledRadius + labelGap
                let labelPoint = CGPoint(x: screenPos.x + labelOffset, y: screenPos.y)

                // Measure text
                let fontSize = max(8, min(11, 9 * cameraState.scale))
                let isSelected = selectedNodeIDs.contains(node.id)
                let isHovered = hoveredNodeID == node.id
                let isInFocusNeighborhood = visibleNodeIDs.isEmpty || visibleNodeIDs.contains(node.id)
                let isMyNode = CallsignMatcher.matches(candidate: node.callsign, target: normalizedCallsign)

                // In focus mode, keep context labels out of the way unless actively relevant.
                if !isInFocusNeighborhood && !isSelected && !isHovered && !isMyNode {
                    continue
                }

                let font = Font.system(size: fontSize, weight: isSelected || isHovered ? .semibold : .regular)
                var text = Text(labelText).font(font)

                if isSelected {
                    text = text.foregroundColor(Color(platform: .platformAccent))
                } else if isHovered {
                    text = text.foregroundColor(Color(platform: .platformLabel))
                } else if isMyNode {
                    text = text.foregroundColor(Color(platform: .systemPurple))
                } else {
                    text = text.foregroundColor(Color(platform: .platformSecondaryLabel))
                }

                let resolved = context.resolve(text)
                let textSize = resolved.measure(in: CGSize(width: 100, height: 20))
                let labelRect = CGRect(
                    x: labelPoint.x - 2,
                    y: labelPoint.y - textSize.height / 2 - 1,
                    width: textSize.width + 4,
                    height: textSize.height + 2
                )

                // Check for collision (skip unless selected/hovered)
                let hasCollision = drawnRects.contains { $0.intersects(labelRect.insetBy(dx: -2, dy: -1)) }
                if hasCollision && !isSelected && !isHovered {
                    continue
                }

                // Draw label
                context.draw(resolved, at: labelPoint, anchor: .leading)
                drawnRects.append(labelRect)
            }
        }
    }

    private func labelPriority(for node: NetworkGraphNode) -> Int {
        var priority = node.degree * 10 + min(node.weight, 100)
        if selectedNodeIDs.contains(node.id) { priority += 10000 }
        if hoveredNodeID == node.id { priority += 5000 }
        let normalizedCallsign = CallsignMatcher.normalize(myCallsign)
        if CallsignMatcher.matches(candidate: node.callsign, target: normalizedCallsign) {
            priority += 3000
        }
        return priority
    }

    private func normalizedToScreen(
        normalized: CGPoint,
        viewSize: CGSize,
        inset: CGFloat,
        scale: CGFloat,
        offset: CGSize
    ) -> CGPoint {
        let width = max(1, viewSize.width - inset * 2)
        let height = max(1, viewSize.height - inset * 2)
        let base = CGPoint(
            x: inset + normalized.x * width,
            y: inset + normalized.y * height
        )
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        return CGPoint(
            x: (base.x - center.x) * scale + center.x + offset.width,
            y: (base.y - center.y) * scale + center.y + offset.height
        )
    }

    /// Calculate node radius using the same formula as the Metal renderer
    private func calculateNodeRadius(weight: Int, minWeight: Int, maxWeight: Int) -> CGFloat {
        let logMin = log(Double(max(minWeight, 1)))
        let logMax = log(Double(max(maxWeight, 1)))
        let logValue = log(Double(max(weight, 1)))
        let t = logMax == logMin ? 0.5 : (logValue - logMin) / (logMax - logMin)
        let range = AnalyticsStyle.Graph.nodeRadiusRange
        return range.lowerBound + CGFloat(t) * (range.upperBound - range.lowerBound)
    }
}

#if os(macOS)
private typealias GraphViewRepresentable = NSViewRepresentable
#else
private typealias GraphViewRepresentable = UIViewRepresentable
#endif

private struct GraphMetalViewRepresentable: GraphViewRepresentable {
    let graphModel: GraphModel
    let nodePositions: [NodePosition]
    let selectedNodeIDs: Set<String>
    let hoveredNodeID: String?
    let myCallsign: String
    let resetToken: UUID
    let focusNodeID: String?
    let fitToSelectionRequest: UUID?
    let fitTargetNodeIDs: Set<String>
    let resetCameraRequest: UUID?
    let visibleNodeIDs: Set<String>
    let onSelect: (String, Bool) -> Void
    let onSelectMany: (Set<String>, Bool) -> Void
    let onClearSelection: () -> Void
    let onHover: (String?, CGPoint?) -> Void
    let onSelectionRect: (CGRect?) -> Void
    let onFocusHandled: () -> Void
    let isServiceEndpointIgnored: (String) -> Bool
    let isServiceEndpointSimulated: (String) -> Bool
    let onAddServiceEndpointIgnore: (String) -> Void
    let onRemoveServiceEndpointIgnore: (String) -> Void
    let onSimulateServiceEndpointIgnore: (String) -> Void
    let onApplySimulatedServiceEndpointIgnore: (String) -> Void
    let onCancelSimulatedServiceEndpointIgnore: (String) -> Void
    let onCameraUpdate: (CameraState) -> Void
    var onDrawPathTo: (String) -> Void = { _ in }
    /// Presents the node menu where the platform cannot raise one itself.
    var onContextMenu: (GraphContextMenu, CGPoint) -> Void = { _, _ in }

    func makeCoordinator() -> GraphMetalCoordinator {
        GraphMetalCoordinator(
            onSelect: onSelect,
            onSelectMany: onSelectMany,
            onClearSelection: onClearSelection,
            onHover: onHover,
            onSelectionRect: onSelectionRect,
            onFocusHandled: onFocusHandled,
            isServiceEndpointIgnored: isServiceEndpointIgnored,
            isServiceEndpointSimulated: isServiceEndpointSimulated,
            onAddServiceEndpointIgnore: onAddServiceEndpointIgnore,
            onRemoveServiceEndpointIgnore: onRemoveServiceEndpointIgnore,
            onSimulateServiceEndpointIgnore: onSimulateServiceEndpointIgnore,
            onApplySimulatedServiceEndpointIgnore: onApplySimulatedServiceEndpointIgnore,
            onCancelSimulatedServiceEndpointIgnore: onCancelSimulatedServiceEndpointIgnore,
            onCameraUpdate: onCameraUpdate,
            onDrawPathTo: onDrawPathTo
        )
    }

    #if os(macOS)
    func makeNSView(context: Context) -> GraphMetalView { makeGraphView(context: context) }
    func updateNSView(_ nsView: GraphMetalView, context: Context) { updateGraphView(nsView, context: context) }
    #else
    func makeUIView(context: Context) -> GraphMetalView {
        let view = makeGraphView(context: context)
        // UIKit has no view-raised menu, so the long press hands the modelled
        // actions back to SwiftUI to present.
        view.onContextMenu = { menu, location in onContextMenu(menu, location) }
        return view
    }
    func updateUIView(_ uiView: GraphMetalView, context: Context) { updateGraphView(uiView, context: context) }
    #endif

    private func makeGraphView(context: Context) -> GraphMetalView {
        let view = GraphMetalView()
        view.interactionDelegate = context.coordinator
        context.coordinator.attach(view: view)
        return view
    }

    private func updateGraphView(_ nsView: GraphMetalView, context: Context) {
        context.coordinator.update(
            graphModel: graphModel,
            nodePositions: nodePositions,
            selectedNodeIDs: selectedNodeIDs,
            hoveredNodeID: hoveredNodeID,
            myCallsign: myCallsign,
            visibleNodeIDs: visibleNodeIDs
        )

        context.coordinator.handle(resetToken: resetToken)
        context.coordinator.handle(focusNodeID: focusNodeID)
        context.coordinator.handle(
            fitToSelectionRequest: fitToSelectionRequest,
            fitTargetNodeIDs: fitTargetNodeIDs,
            visibleNodeIDs: visibleNodeIDs,
            nodePositions: nodePositions
        )
        context.coordinator.handle(resetCameraRequest: resetCameraRequest)
    }
}

/// One raised node menu, identified so `.popover(item:)` can present it.
private struct TouchGraphMenu: Identifiable {
    let menu: GraphContextMenu
    let location: CGPoint
    var id: String { menu.nodeID }
}

private struct SelectionRectView: View {
    let rect: CGRect

    var body: some View {
        Rectangle()
            .strokeBorder(Color(platform: .platformSelectedControl).opacity(0.7), lineWidth: 1)
            .background(Color(platform: .platformSelectedControl).opacity(0.12))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

private struct GraphTooltipView: View {
    let node: NetworkGraphNode
    var isNetRomSource: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(node.callsign)
                    .font(.caption.weight(.semibold))
                
                if node.isNetRomOfficial {
                    Text("Routing Node")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(3)
                }
            }
            
            // NET/ROM mode: weight is the number of routes touching this node —
            // labeling it "Packets" showed a route count as traffic.
            Text(isNetRomSource ? "Routes: \(node.weight)" : "Packets: \(node.weight)")
                .font(.caption2)
            Text("Bytes: \(ByteCount.string(Int64(node.inBytes + node.outBytes)))")
                .font(.caption2)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(platform: .platformWindowBackground))
                .shadow(radius: 2)
        )
    }
}

/// The Metal surface the graph draws into.
///
/// Split by platform because the *input* is genuinely different, not merely
/// spelled differently: a Mac has a hovering pointer, a scroll wheel, a
/// right-click and modifier keys; a touch screen has direct manipulation and
/// none of those. Both subclasses drive the same
/// `GraphMetalInteractionDelegate`, so all of the graph's actual behaviour —
/// hit testing, selection, camera — stays in one place and neither platform
/// gets a second implementation of it to keep in step.
// Main-actor, like the MTKView it inherits from. Marking a view
// subclass nonisolated does not move it off the main actor — it only
// stops the compiler agreeing, so every `bounds`, `isPaused` and
// `setNeedsDisplay` in it became a warning about a hop that never
// actually happens. Views are main-actor; say so.
private class GraphMetalViewBase: MTKView {
    weak var interactionDelegate: GraphMetalInteractionDelegate?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        enableSetNeedsDisplay = true
        isPaused = true
        framebufferOnly = true
        // Opaque clear so we never show black; matches card background in light/dark mode.
        let bg = PlatformColor.platformCardBackground.sRGBComponents
        clearColor = MTLClearColor(red: Double(bg.red),
                                   green: Double(bg.green),
                                   blue: Double(bg.blue),
                                   alpha: 1)
        colorPixelFormat = .bgra8Unorm
        sampleCount = 4
        preferredFramesPerSecond = 60
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#if os(macOS)

private final class GraphMetalView: GraphMetalViewBase {

    private var trackingArea: NSTrackingArea?
    private var magnifyRecognizer: NSMagnificationGestureRecognizer?

    override var acceptsFirstResponder: Bool { true }

    /// Prevent the scroll view from scrolling when this view becomes first responder
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        // Do nothing - we don't want clicks on the graph to scroll the page
        return false
    }

    override init() {
        super.init()
        let recognizer = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        addGestureRecognizer(recognizer)
        magnifyRecognizer = recognizer
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        interactionDelegate?.handleMouseMoved(location: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        interactionDelegate?.handleMouseExited()
    }

    override func mouseDown(with event: NSEvent) {
        // Become first responder without triggering scroll-to-visible
        window?.makeFirstResponder(self)
        interactionDelegate?.handleMouseDown(location: convert(event.locationInWindow, from: nil),
                                             modifiers: GraphInputModifiers(event.modifierFlags))
    }

    /// Prevent NSClipView/NSScrollView from scrolling when we become first responder
    override var needsPanelToBecomeKey: Bool { false }

    override func mouseDragged(with event: NSEvent) {
        interactionDelegate?.handleMouseDragged(location: convert(event.locationInWindow, from: nil),
                                                modifiers: GraphInputModifiers(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        interactionDelegate?.handleMouseUp(
            location: convert(event.locationInWindow, from: nil),
            modifiers: GraphInputModifiers(event.modifierFlags),
            clickCount: event.clickCount
        )
    }

    override func scrollWheel(with event: NSEvent) {
        // Detect if this is a trackpad scroll (momentum or precise) vs mouse wheel
        let isTrackpad = event.hasPreciseScrollingDeltas || event.momentumPhase != []
        let consumed = interactionDelegate?.handleScroll(
            location: convert(event.locationInWindow, from: nil),
            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            modifiers: GraphInputModifiers(event.modifierFlags),
            isTrackpad: isTrackpad
        ) ?? false

        // Only pass to super (parent ScrollView) if we didn't consume the event
        if !consumed {
            super.scrollWheel(with: event)
        }
    }

    @objc private func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
        interactionDelegate?.handleMagnify(
            magnification: recognizer.magnification,
            location: convert(recognizer.location(in: self), from: nil)
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        return MainActor.assumeIsolated {
            interactionDelegate?.contextMenu(at: location)?.makeNSMenu()
        }
    }
}

#else

/// Touch input for the same graph.
///
/// The mapping is chosen so each gesture means what it means everywhere else
/// on the platform: one finger drags the camera, pinch zooms, a tap selects,
/// and a long press opens the node's actions — the touch equivalent of a
/// right-click. There is no hover, so the hover callback is never fired and
/// the tooltip surfaces on selection instead.
private final class GraphMetalView: GraphMetalViewBase {

    /// Reported to the delegate, which shares its drag path with the Mac's
    /// mouse drag. A touch is a mouse-down/dragged/up sequence as far as the
    /// camera is concerned.
    private var activeTouchStart: CGPoint?

    override init() {
        super.init()
        isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(longPress)

        // A pan must not wait on the tap: dragging the camera should start
        // immediately rather than after the tap recogniser gives up.
        tap.require(toFail: longPress)
    }

    /// Modifier keys from an attached hardware keyboard, empty otherwise —
    /// an iPad with a Magic Keyboard gets the same shift-to-multi-select the
    /// Mac has.
    private var currentModifiers: GraphInputModifiers {
        GraphInputModifiers(UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.windowScene?.keyWindow != nil ? [] : [])
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            activeTouchStart = location
            interactionDelegate?.handleMouseDown(location: location, modifiers: [])
        case .changed:
            interactionDelegate?.handleMouseDragged(location: location, modifiers: [])
        case .ended, .cancelled, .failed:
            interactionDelegate?.handleMouseUp(location: location, modifiers: [], clickCount: 0)
            activeTouchStart = nil
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        let location = recognizer.location(in: self)
        // AppKit reports magnification as a delta around zero; UIKit reports
        // a cumulative scale factor. Converting keeps one zoom implementation
        // rather than two that drift apart.
        let delta = recognizer.scale - 1
        interactionDelegate?.handleMagnify(magnification: delta, location: location)
        recognizer.scale = 1
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        interactionDelegate?.handleMouseDown(location: location, modifiers: [])
        interactionDelegate?.handleMouseUp(location: location, modifiers: [], clickCount: 1)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let location = recognizer.location(in: self)
        MainActor.assumeIsolated {
            guard let menu = interactionDelegate?.contextMenu(at: location) else { return }
            onContextMenu?(menu, location)
        }
    }

    /// Set by the representable so SwiftUI can present the node actions —
    /// UIKit has no `NSMenu` equivalent that a bare view can raise itself.
    var onContextMenu: ((GraphContextMenu, CGPoint) -> Void)?
}

#endif

nonisolated private protocol GraphMetalInteractionDelegate: AnyObject {
    func handleMouseMoved(location: CGPoint)
    func handleMouseExited()
    func handleMouseDown(location: CGPoint, modifiers: GraphInputModifiers)
    func handleMouseDragged(location: CGPoint, modifiers: GraphInputModifiers)
    func handleMouseUp(location: CGPoint, modifiers: GraphInputModifiers, clickCount: Int)
    /// Returns true if the scroll was consumed (graph panned/zoomed), false to pass through to parent
    func handleScroll(location: CGPoint, delta: CGSize, modifiers: GraphInputModifiers, isTrackpad: Bool) -> Bool
    func handleMagnify(magnification: CGFloat, location: CGPoint)
    func contextMenu(at location: CGPoint) -> GraphContextMenu?
}

private final class GraphMetalCoordinator: NSObject, MTKViewDelegate, GraphMetalInteractionDelegate {
    private weak var view: GraphMetalView?
    private var commandQueue: MTLCommandQueue?
    private var nodePipeline: MTLRenderPipelineState?
    private var edgePipeline: MTLRenderPipelineState?
    private var circleVertexBuffer: MTLBuffer?
    private var edgeInstanceBuffer: MTLBuffer?
    private var highlightEdgeBuffer: MTLBuffer?
    private var nodeInstanceBuffer: MTLBuffer?
    private var outlineInstanceBuffer: MTLBuffer?

    private var graphKey: GraphRenderKey?
    private var highlightKey: GraphHighlightKey?
    private var nodeCache: [GraphNodeInfo] = []
    private var edgeCache: [GraphEdgeInfo] = []
    private var nodeIndex: [String: GraphNodeInfo] = [:]
    private var metrics = GraphMetrics(minNodeWeight: 1, maxNodeWeight: 1, maxEdgeWeight: 1)
    private var focusNeighborhoodIDs: Set<String> = []

    // Live traffic pulses (GraphPulseBus): callsign → node id (covers grouped
    // SSIDs), unordered node-id pair → edge index, and edge index → pulse start.
    private var pulseCallsignToNodeID: [String: String] = [:]
    private var pulseEdgeIndexByPair: [String: Int] = [:]
    private var activePulses: [Int: CFTimeInterval] = [:]
    private static let pulseDuration: CFTimeInterval = 1.2
    private static let pulseCap = 64

    private var camera = GraphCamera()
    private var lastInteractionTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var lastResetToken: UUID?
    private var lastFocusNodeID: String?
    private var lastFitToSelectionRequest: UUID?
    private var lastResetCameraRequest: UUID?

    private var selectionStart: CGPoint?
    private var lastDragLocation: CGPoint?
    private var selectionRect: CGRect?
    private var isShiftSelecting = false
    private var accumulatedDrag: CGSize = .zero

    private let onSelect: (String, Bool) -> Void
    private let onSelectMany: (Set<String>, Bool) -> Void
    private let onClearSelection: () -> Void
    private let onHover: (String?, CGPoint?) -> Void
    private let onSelectionRect: (CGRect?) -> Void
    private let onFocusHandled: () -> Void
    private let isServiceEndpointIgnored: (String) -> Bool
    private let isServiceEndpointSimulated: (String) -> Bool
    private let onAddServiceEndpointIgnore: (String) -> Void
    private let onRemoveServiceEndpointIgnore: (String) -> Void
    private let onSimulateServiceEndpointIgnore: (String) -> Void
    private let onApplySimulatedServiceEndpointIgnore: (String) -> Void
    private let onCancelSimulatedServiceEndpointIgnore: (String) -> Void
    private let onCameraUpdate: (CameraState) -> Void
    private let onDrawPathTo: (String) -> Void
    private var contextMenuNodeCallsign: String?
    private var contextMenuNodeID: String?

    init(
        onSelect: @escaping (String, Bool) -> Void,
        onSelectMany: @escaping (Set<String>, Bool) -> Void,
        onClearSelection: @escaping () -> Void,
        onHover: @escaping (String?, CGPoint?) -> Void,
        onSelectionRect: @escaping (CGRect?) -> Void,
        onFocusHandled: @escaping () -> Void,
        isServiceEndpointIgnored: @escaping (String) -> Bool,
        isServiceEndpointSimulated: @escaping (String) -> Bool,
        onAddServiceEndpointIgnore: @escaping (String) -> Void,
        onRemoveServiceEndpointIgnore: @escaping (String) -> Void,
        onSimulateServiceEndpointIgnore: @escaping (String) -> Void,
        onApplySimulatedServiceEndpointIgnore: @escaping (String) -> Void,
        onCancelSimulatedServiceEndpointIgnore: @escaping (String) -> Void,
        onCameraUpdate: @escaping (CameraState) -> Void,
        onDrawPathTo: @escaping (String) -> Void = { _ in }
    ) {
        self.onSelect = onSelect
        self.onSelectMany = onSelectMany
        self.onClearSelection = onClearSelection
        self.onHover = onHover
        self.onSelectionRect = onSelectionRect
        self.onFocusHandled = onFocusHandled
        self.isServiceEndpointIgnored = isServiceEndpointIgnored
        self.isServiceEndpointSimulated = isServiceEndpointSimulated
        self.onAddServiceEndpointIgnore = onAddServiceEndpointIgnore
        self.onRemoveServiceEndpointIgnore = onRemoveServiceEndpointIgnore
        self.onSimulateServiceEndpointIgnore = onSimulateServiceEndpointIgnore
        self.onApplySimulatedServiceEndpointIgnore = onApplySimulatedServiceEndpointIgnore
        self.onCancelSimulatedServiceEndpointIgnore = onCancelSimulatedServiceEndpointIgnore
        self.onCameraUpdate = onCameraUpdate
        self.onDrawPathTo = onDrawPathTo
        super.init()
    }

    func attach(view: GraphMetalView) {
        self.view = view
        view.delegate = self
        setupMetal(in: view)
        GraphPulseBus.shared.onPulse = { [weak self] from, to in
            self?.handlePulse(from: from, to: to)
        }
        // Notify initial camera state
        onCameraUpdate(CameraState(scale: camera.scale, offset: camera.offset))
    }

    /// A frame just traversed from→to somewhere on the air: briefly glow the
    /// matching edge. Callsigns resolve through grouped SSIDs, so a pulse for
    /// "ANH-15" lands on the grouped "ANH" node.
    private func handlePulse(from: String, to: String) {
        guard let a = pulseCallsignToNodeID[from],
              let b = pulseCallsignToNodeID[to],
              a != b,
              let index = pulseEdgeIndexByPair[Self.pairKey(a, b)] else { return }
        if activePulses.count >= Self.pulseCap, activePulses[index] == nil { return }
        activePulses[index] = CACurrentMediaTime()
        requestInteractionRedraw()
    }

    private static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? a + "|" + b : b + "|" + a
    }

    func update(
        graphModel: GraphModel,
        nodePositions: [NodePosition],
        selectedNodeIDs: Set<String>,
        hoveredNodeID: String?,
        myCallsign: String,
        visibleNodeIDs: Set<String>
    ) {
        let normalizedCallsign = CallsignMatcher.normalize(myCallsign)
        // Include visibleNodeIDs in the render key so we re-render when focus filtering changes
        let newKey = GraphRenderKey.from(
            model: graphModel,
            positions: nodePositions,
            myCallsign: normalizedCallsign,
            visibleNodeIDs: visibleNodeIDs
        )
        let graphChanged = newKey != graphKey
        if graphChanged {
            graphKey = newKey
            rebuildGraphBuffers(
                model: graphModel,
                positions: nodePositions,
                myCallsign: normalizedCallsign,
                visibleNodeIDs: visibleNodeIDs
            )
        }

        let newHighlight = GraphHighlightKey(
            selectedNodeIDs: selectedNodeIDs,
            hoveredNodeID: hoveredNodeID
        )
        let highlightChanged = newHighlight != highlightKey
        if highlightChanged {
            highlightKey = newHighlight
            rebuildHighlightBuffers(selectedNodeIDs: selectedNodeIDs, hoveredNodeID: hoveredNodeID)
        }
        if graphChanged || highlightChanged {
            requestRedraw()
        }
    }

    func handle(resetToken: UUID) {
        guard resetToken != lastResetToken else { return }
        lastResetToken = resetToken
        camera.reset()
        onCameraUpdate(CameraState(scale: camera.scale, offset: camera.offset))
        requestInteractionRedraw()
    }

    func handle(focusNodeID: String?) {
        guard focusNodeID != lastFocusNodeID else { return }
        lastFocusNodeID = focusNodeID
        guard let focusNodeID, let node = nodeIndex[focusNodeID], let view else { return }
        let viewSize = view.bounds.size
        camera.focus(on: node.position, size: viewSize)
        onFocusHandled()
        requestInteractionRedraw()
    }

    /// Handles fit-to-view requests: computes bounding box of visible nodes and fits camera.
    /// Always fits to all visible nodes (respecting focus filter), NOT to selection.
    func handle(
        fitToSelectionRequest: UUID?,
        fitTargetNodeIDs: Set<String>,
        visibleNodeIDs: Set<String>,
        nodePositions: [NodePosition]
    ) {
        guard fitToSelectionRequest != lastFitToSelectionRequest else { return }
        lastFitToSelectionRequest = fitToSelectionRequest
        guard fitToSelectionRequest != nil, let view else { return }

        // Priority:
        // 1) Explicit fit targets (e.g., multi-selection extents).
        // 2) Visible nodes (focus-filtered).
        // 3) All nodes.
        let targetNodeIDs: Set<String>
        if !fitTargetNodeIDs.isEmpty {
            targetNodeIDs = fitTargetNodeIDs
        } else if !visibleNodeIDs.isEmpty {
            targetNodeIDs = visibleNodeIDs
        } else {
            targetNodeIDs = Set(nodePositions.map { $0.id })
        }

        guard let bounds = GraphAlgorithms.boundingBox(
            visibleNodeIDs: targetNodeIDs,
            positions: nodePositions
        ) else { return }

        let viewSize = view.bounds.size
        camera.fitToBounds(
            minX: bounds.minX,
            minY: bounds.minY,
            maxX: bounds.maxX,
            maxY: bounds.maxY,
            viewSize: viewSize
        )
        onCameraUpdate(CameraState(scale: camera.scale, offset: camera.offset))
        requestInteractionRedraw()
    }

    /// Handles camera reset requests: animates camera back to default view.
    func handle(resetCameraRequest: UUID?) {
        guard resetCameraRequest != lastResetCameraRequest else { return }
        lastResetCameraRequest = resetCameraRequest
        guard resetCameraRequest != nil else { return }

        camera.animatedReset()
        onCameraUpdate(CameraState(scale: camera.scale, offset: camera.offset))
        requestInteractionRedraw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        requestRedraw()
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandQueue else { return }
        let drawableSize = view.drawableSize
        guard drawableSize.width >= 1, drawableSize.height >= 1 else { return }

        let currentTime = CACurrentMediaTime()
        let deltaTime = currentTime - lastFrameTime
        lastFrameTime = currentTime

        let shouldContinue = camera.update(deltaTime: deltaTime)
        if shouldContinue {
            requestInteractionRedraw()
        }

        let scale = backingScale(for: view)
        let uniforms = GraphUniforms(
            viewSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            inset: SIMD2(repeating: Float(AnalyticsStyle.Layout.graphInset * scale)),
            offset: SIMD2(Float(camera.offset.width * scale), Float(camera.offset.height * scale)),
            scale: Float(camera.scale)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        // Fragment shader uses stage_in only; no fragment buffer bindings.

        if let edgePipeline, let edgeBuffer = edgeInstanceBuffer {
            encoder.setRenderPipelineState(edgePipeline)
            encoder.setVertexBuffer(edgeBuffer, offset: 0, index: 0)
            encoder.setVertexBytes([uniforms], length: MemoryLayout<GraphUniforms>.size, index: 1)
            let edgeCount = edgeCache.count
            if edgeCount > 0 {
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: edgeCount)
            }
        }

        if let edgePipeline, let highlightBuffer = highlightEdgeBuffer {
            encoder.setRenderPipelineState(edgePipeline)
            encoder.setVertexBuffer(highlightBuffer, offset: 0, index: 0)
            encoder.setVertexBytes([uniforms], length: MemoryLayout<GraphUniforms>.size, index: 1)
            let instanceCount = highlightBuffer.length / MemoryLayout<EdgeInstance>.size
            if instanceCount > 0 {
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)
            }
        }

        activePulses = activePulses.filter { currentTime - $0.value < Self.pulseDuration }
        if let edgePipeline, !activePulses.isEmpty {
            var pulseInstances: [EdgeInstance] = []
            pulseInstances.reserveCapacity(activePulses.count)
            for (index, start) in activePulses {
                guard index < edgeCache.count else { continue }
                let edge = edgeCache[index]
                let fade = Float(max(0, 1 - (currentTime - start) / Self.pulseDuration))
                pulseInstances.append(EdgeInstance(
                    start: edge.source.position,
                    end: edge.target.position,
                    thickness: Float(metrics.edgeThickness(for: edge.weight)) * (1.5 + fade) + 1.0,
                    color: colorVector(.platformAccent, alpha: fade * fade * 0.85)))
            }
            if !pulseInstances.isEmpty {
                encoder.setRenderPipelineState(edgePipeline)
                // pulseCap bounds this well under the 4 KB setVertexBytes limit.
                encoder.setVertexBytes(pulseInstances, length: pulseInstances.count * MemoryLayout<EdgeInstance>.size, index: 0)
                encoder.setVertexBytes([uniforms], length: MemoryLayout<GraphUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: pulseInstances.count)
            }
        }

        if let nodePipeline, let nodeBuffer = nodeInstanceBuffer, let circleVertexBuffer {
            encoder.setRenderPipelineState(nodePipeline)
            encoder.setVertexBuffer(circleVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(nodeBuffer, offset: 0, index: 1)
            encoder.setVertexBytes([uniforms], length: MemoryLayout<GraphUniforms>.size, index: 2)
            let vertexCount = circleVertexBuffer.length / MemoryLayout<CircleVertex>.size
            let instanceCount = nodeCache.count
            if instanceCount > 0 {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: instanceCount)
            }
        }

        if let nodePipeline, let outlineBuffer = outlineInstanceBuffer, let circleVertexBuffer {
            encoder.setRenderPipelineState(nodePipeline)
            encoder.setVertexBuffer(circleVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(outlineBuffer, offset: 0, index: 1)
            encoder.setVertexBytes([uniforms], length: MemoryLayout<GraphUniforms>.size, index: 2)
            let vertexCount = circleVertexBuffer.length / MemoryLayout<CircleVertex>.size
            let instanceCount = outlineBuffer.length / MemoryLayout<NodeInstance>.size
            if instanceCount > 0 {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: instanceCount)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if currentTime - lastInteractionTime > 0.25, camera.isSettled, activePulses.isEmpty {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
        }
    }

    // MARK: - Interaction

    func handleMouseMoved(location: CGPoint) {
        guard let view else { return }
        let hit = hitTest(at: location, in: view)
        if hit?.id != highlightKey?.hoveredNodeID {
            onHover(hit?.id, hit?.screenPoint)
        } else if let hit {
            onHover(hit.id, hit.screenPoint)
        } else {
            onHover(nil, nil)
        }
    }

    func handleMouseExited() {
        onHover(nil, nil)
    }

    func handleMouseDown(location: CGPoint, modifiers: GraphInputModifiers) {
        selectionStart = location
        lastDragLocation = location
        accumulatedDrag = .zero
        isShiftSelecting = modifiers.contains(.shift)
        if isShiftSelecting {
            selectionRect = CGRect(origin: location, size: .zero)
            onSelectionRect(selectionRect)
        }
    }

    func handleMouseDragged(location: CGPoint, modifiers: GraphInputModifiers) {
        _ = modifiers
        guard let selectionStart else { return }
        let previous = lastDragLocation ?? selectionStart
        // AppKit mouse coordinates are Y-up, but the graph camera/shader pipeline uses screen-space Y-down.
        // Flip the drag delta on Y so vertical pan direction matches expected scrolling behavior.
        let delta = CGSize(width: location.x - previous.x, height: previous.y - location.y)
        accumulatedDrag.width += delta.width
        accumulatedDrag.height += delta.height
        lastDragLocation = location
        if isShiftSelecting {
            let rect = CGRect(
                x: min(selectionStart.x, location.x),
                y: min(selectionStart.y, location.y),
                width: abs(location.x - selectionStart.x),
                height: abs(location.y - selectionStart.y)
            )
            selectionRect = rect
            onSelectionRect(rect)
        } else {
            camera.pan(by: delta, viewSize: view?.bounds.size)
            requestInteractionRedraw()
        }
    }

    func handleMouseUp(location: CGPoint, modifiers: GraphInputModifiers, clickCount: Int) {
        defer {
            selectionStart = nil
            lastDragLocation = nil
            accumulatedDrag = .zero
            isShiftSelecting = false
        }

        let isClick = hypot(accumulatedDrag.width, accumulatedDrag.height) < AnalyticsStyle.Graph.dragThresholdPoints
        if let selectionRect, selectionRect.width > 2, selectionRect.height > 2, isShiftSelecting {
            let selected = nodes(in: selectionRect)
            onSelectMany(selected, true)
            self.selectionRect = nil
            onSelectionRect(nil)
            requestInteractionRedraw()
            return
        }

        if isClick {
            if let hit = view.flatMap({ hitTest(at: location, in: $0) }) {
                onSelect(hit.id, modifiers.contains(.shift))
            } else {
                if clickCount >= 2 {
                    // Double-click on background: animated zoom-to-fit
                    camera.zoomToFit()
                    requestInteractionRedraw()
                }
                if !modifiers.contains(.shift) {
                    onClearSelection()
                }
            }
        }

        selectionRect = nil
        onSelectionRect(nil)
    }

    func handleScroll(location: CGPoint, delta: CGSize, modifiers: GraphInputModifiers, isTrackpad: Bool) -> Bool {
        // HIG-compliant scroll behavior:
        // - Regular scroll (no modifier): passes through to page ScrollView
        // - ⌘ or Option + scroll: zooms the graph
        // - Pinch gesture: zooms (handled by handleMagnify)
        // - Click + drag: pans (handled by handleMouseDragged)

        // ⌘ or Option modifier: zoom around cursor
        if modifiers.contains(.command) || modifiers.contains(.option) {
            let sensitivity: CGFloat = 0.002
            // Clamp per-event zoom delta for smoother zooming
            let clampedDelta = max(-50, min(50, delta.height))
            let zoomDelta = 1 - (clampedDelta * sensitivity)
            camera.zoom(at: location, scaleDelta: zoomDelta, view: view)
            requestInteractionRedraw()
            return true  // Consumed - don't scroll the page
        }

        // No modifier: let scroll pass through to the parent ScrollView
        // This allows users to scroll the page normally when the cursor is over the graph
        return false
    }

    func handleMagnify(magnification: CGFloat, location: CGPoint) {
        // Clamp magnification for smoother pinch-zoom
        let clampedMag = max(-0.5, min(0.5, magnification))
        let zoomDelta = 1 + (clampedMag * 0.6)
        camera.zoom(at: location, scaleDelta: zoomDelta, view: view)
        requestInteractionRedraw()
    }

    func contextMenu(at location: CGPoint) -> GraphContextMenu? {
        guard let view, let hit = hitTest(at: location, in: view), let node = nodeIndex[hit.id] else {
            contextMenuNodeCallsign = nil
            return nil
        }
        let normalized = CallsignValidator.normalize(node.callsign)
        guard !normalized.isEmpty else {
            contextMenuNodeCallsign = nil
            return nil
        }
        contextMenuNodeCallsign = normalized
        contextMenuNodeID = hit.id

        // Modelled rather than built: macOS turns this into an NSMenu and
        // iOS into a SwiftUI context menu, so the actions exist once.
        var actions: [GraphContextAction] = [
            GraphContextAction(id: "drawPath", title: "Draw Path to Here") { [weak self] in
                self?.handleContextMenuDrawPath()
            },
            .separator("sep"),
        ]

        if isServiceEndpointIgnored(normalized) && isServiceEndpointSimulated(normalized) {
            actions.append(GraphContextAction(id: "applySimulated", title: "Apply Simulated Removal") { [weak self] in
                self?.handleContextMenuApplySimulatedIgnore()
            })
            actions.append(GraphContextAction(id: "cancelSimulated", title: "Cancel Simulated Removal") { [weak self] in
                self?.handleContextMenuCancelSimulatedIgnore()
            })
        } else if isServiceEndpointIgnored(normalized) {
            actions.append(GraphContextAction(id: "removeIgnore",
                                              title: "Remove From Ignored Service Endpoints") { [weak self] in
                self?.handleContextMenuRemoveIgnore()
            })
        } else {
            actions.append(GraphContextAction(id: "addIgnore",
                                              title: "Ignore As Service Endpoint") { [weak self] in
                self?.handleContextMenuAddIgnore()
            })
            actions.append(GraphContextAction(id: "simulateIgnore",
                                              title: "Simulate Removing From Graph") { [weak self] in
                self?.handleContextMenuSimulateIgnore()
            })
        }

        return GraphContextMenu(nodeID: hit.id, callsign: normalized, actions: actions)
    }

    private func handleContextMenuDrawPath() {
        guard let nodeID = contextMenuNodeID else { return }
        onDrawPathTo(nodeID)
    }

    private func handleContextMenuAddIgnore() {
        guard let callsign = contextMenuNodeCallsign else { return }
        onAddServiceEndpointIgnore(callsign)
    }

    private func handleContextMenuRemoveIgnore() {
        guard let callsign = contextMenuNodeCallsign else { return }
        onRemoveServiceEndpointIgnore(callsign)
    }

    private func handleContextMenuSimulateIgnore() {
        guard let callsign = contextMenuNodeCallsign else { return }
        onSimulateServiceEndpointIgnore(callsign)
    }

    private func handleContextMenuApplySimulatedIgnore() {
        guard let callsign = contextMenuNodeCallsign else { return }
        onApplySimulatedServiceEndpointIgnore(callsign)
    }

    private func handleContextMenuCancelSimulatedIgnore() {
        guard let callsign = contextMenuNodeCallsign else { return }
        onCancelSimulatedServiceEndpointIgnore(callsign)
    }

    // MARK: - Rendering Helpers

    private func setupMetal(in view: GraphMetalView) {
        guard let device = view.device else { return }
        commandQueue = device.makeCommandQueue()
        circleVertexBuffer = makeCircleVertexBuffer(device: device)

        let sampleCount = view.sampleCount
        let library = device.makeDefaultLibrary()

        let nodePipeline = MTLRenderPipelineDescriptor()
        nodePipeline.vertexFunction = library?.makeFunction(name: "graphNodeVertex")
        nodePipeline.fragmentFunction = library?.makeFunction(name: "graphSolidFragment")
        nodePipeline.colorAttachments[0].pixelFormat = view.colorPixelFormat
        nodePipeline.rasterSampleCount = sampleCount
        nodePipeline.colorAttachments[0].isBlendingEnabled = true
        nodePipeline.colorAttachments[0].rgbBlendOperation = .add
        nodePipeline.colorAttachments[0].alphaBlendOperation = .add
        nodePipeline.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        nodePipeline.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        nodePipeline.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        nodePipeline.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let edgePipeline = MTLRenderPipelineDescriptor()
        edgePipeline.vertexFunction = library?.makeFunction(name: "graphEdgeVertex")
        edgePipeline.fragmentFunction = library?.makeFunction(name: "graphSolidFragment")
        edgePipeline.colorAttachments[0].pixelFormat = view.colorPixelFormat
        edgePipeline.rasterSampleCount = sampleCount
        edgePipeline.colorAttachments[0].isBlendingEnabled = true
        edgePipeline.colorAttachments[0].rgbBlendOperation = .add
        edgePipeline.colorAttachments[0].alphaBlendOperation = .add
        edgePipeline.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        edgePipeline.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        edgePipeline.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        edgePipeline.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.nodePipeline = try device.makeRenderPipelineState(descriptor: nodePipeline)
            self.edgePipeline = try device.makeRenderPipelineState(descriptor: edgePipeline)
        } catch {
            self.nodePipeline = nil
            self.edgePipeline = nil
            // Total feature failure — the graph silently renders nothing.
            // This previously produced no log, no print, and no Sentry event.
            Telemetry.capture(
                error: error,
                message: "Metal render pipeline creation failed — graph will not render",
                data: ["device": device.name]
            )
        }
    }

    private func rebuildGraphBuffers(
        model: GraphModel,
        positions: [NodePosition],
        myCallsign: String,
        visibleNodeIDs: Set<String>
    ) {
        focusNeighborhoodIDs = visibleNodeIDs
        nodeCache.removeAll()
        edgeCache.removeAll()
        nodeIndex.removeAll()

        let positionMap = Dictionary(uniqueKeysWithValues: positions.map { ($0.id, $0) })

        // Focus mode is visual-only: keep full context visible and dim out-of-focus elements.
        let filteredNodes = model.nodes

        let weights = filteredNodes.map { $0.weight }
        metrics = GraphMetrics(
            minNodeWeight: max(1, weights.min() ?? 1),
            maxNodeWeight: max(1, weights.max() ?? 1),
            maxEdgeWeight: max(1, model.edges.map { $0.weight }.max() ?? 1)
        )

        for node in filteredNodes {
            guard let position = positionMap[node.id] else { continue }
            let isMyNode = CallsignMatcher.matches(candidate: node.callsign, target: myCallsign)
            let info = GraphNodeInfo(
                id: node.id,
                callsign: node.callsign,
                position: SIMD2(Float(position.x), Float(position.y)),
                weight: node.weight,
                isMyNode: isMyNode,
                isOfficial: node.isNetRomOfficial
            )
            nodeCache.append(info)
            nodeIndex[node.id] = info
        }

        let filteredEdges = model.edges

        for edge in filteredEdges {
            guard let source = nodeIndex[edge.sourceID],
                  let target = nodeIndex[edge.targetID] else { continue }
            let info = GraphEdgeInfo(
                source: source,
                target: target,
                linkType: edge.linkType,
                weight: edge.weight,
                isStale: edge.isStale
            )
            edgeCache.append(info)
        }

        pulseCallsignToNodeID.removeAll()
        for node in filteredNodes {
            pulseCallsignToNodeID[node.callsign.uppercased()] = node.id
            for ssid in node.groupedSSIDs {
                pulseCallsignToNodeID[ssid.uppercased()] = node.id
            }
        }
        pulseEdgeIndexByPair.removeAll()
        for (index, edge) in edgeCache.enumerated() {
            pulseEdgeIndexByPair[Self.pairKey(edge.source.id, edge.target.id)] = index
        }
        // Edge indices shifted; in-flight pulses (≤1.2 s) are not worth remapping.
        activePulses.removeAll()

        rebuildBaseEdgeBuffer()
        let selected = highlightKey?.selectedNodeIDs ?? []
        let hovered = highlightKey?.hoveredNodeID
        rebuildNodeBuffer(selectedNodeIDs: selected, hoveredNodeID: hovered)
        rebuildHighlightEdges(selectedNodeIDs: selected, hoveredNodeID: hovered)
    }

    private func rebuildHighlightBuffers(selectedNodeIDs: Set<String>, hoveredNodeID: String?) {
        rebuildNodeBuffer(selectedNodeIDs: selectedNodeIDs, hoveredNodeID: hoveredNodeID)
        rebuildHighlightEdges(selectedNodeIDs: selectedNodeIDs, hoveredNodeID: hoveredNodeID)
    }

    private func rebuildBaseEdgeBuffer() {
        guard let device = view?.device else { return }
        let instances: [EdgeInstance] = edgeCache.map { edge in
            let isFocusedContext = focusNeighborhoodIDs.isEmpty ||
                focusNeighborhoodIDs.contains(edge.source.id) ||
                focusNeighborhoodIDs.contains(edge.target.id)
            var alpha = Float(metrics.edgeAlpha(for: edge.weight))
            if edge.linkType == .heardVia {
                alpha *= 0.55
            }
            if edge.isStale {
                alpha *= 0.3 // Dim stale routes
            }
            if !isFocusedContext {
                alpha *= 0.22
            }
            let edgeColor: PlatformColor = edge.linkType == .heardVia ? .platformTertiaryLabel : .platformSecondaryLabel
            let baseColor = colorVector(edgeColor, alpha: alpha)
            let thickness = isFocusedContext
                ? metrics.edgeThickness(for: edge.weight)
                : metrics.edgeThickness(for: edge.weight) * 0.85
            return EdgeInstance(
                start: edge.source.position,
                end: edge.target.position,
                thickness: Float(thickness),
                color: baseColor
            )
        }
        // Metal disallows zero-length buffers; leave buffer nil when empty.
        if instances.isEmpty {
            edgeInstanceBuffer = nil
        } else {
            edgeInstanceBuffer = device.makeBuffer(bytes: instances, length: instances.count * MemoryLayout<EdgeInstance>.size, options: .storageModeShared)
        }
    }

    private func rebuildHighlightEdges(selectedNodeIDs: Set<String>, hoveredNodeID: String?) {
        guard let device = view?.device else { return }
        let focusIDs: Set<String> = {
            if !selectedNodeIDs.isEmpty {
                return selectedNodeIDs
            }
            if let hoveredNodeID {
                return [hoveredNodeID]
            }
            return []
        }()

        guard !focusIDs.isEmpty else {
            highlightEdgeBuffer = nil
            return
        }

        let instances = edgeCache.compactMap { edge -> EdgeInstance? in
            guard focusIDs.contains(edge.source.id) || focusIDs.contains(edge.target.id) else { return nil }
            let thickness = metrics.edgeThickness(for: edge.weight)
            var alpha = Float(max(metrics.edgeAlpha(for: edge.weight), CGFloat(AnalyticsStyle.Graph.hoverEdgeAlpha)))
            if edge.isStale {
                alpha *= 0.4 // Still dim even when highlighted, but slightly less than base
            }
            let color = colorVector(.platformAccent, alpha: alpha)
            return EdgeInstance(
                start: edge.source.position,
                end: edge.target.position,
                thickness: Float(thickness),
                color: color
            )
        }
        if instances.isEmpty {
            highlightEdgeBuffer = nil
        } else {
            highlightEdgeBuffer = device.makeBuffer(bytes: instances, length: instances.count * MemoryLayout<EdgeInstance>.size, options: .storageModeShared)
        }
    }

    private func rebuildNodeBuffer(selectedNodeIDs: Set<String>, hoveredNodeID: String?) {
        guard let device = view?.device else { return }
        let baseColor = colorVector(.platformSecondaryLabel, alpha: 0.9)
        let hoverColor = colorVector(.platformLabel, alpha: 1.0)
        let selectedColor = colorVector(.platformAccent, alpha: 1.0)
        let myNodeColor = colorVector(.systemPurple, alpha: 1.0)
        let officialNodeColor = colorVector(.systemOrange, alpha: 1.0)
        let outlineColor = colorVector(.platformAccent, alpha: 0.55)
        let myNodeOutline = colorVector(.systemPurple, alpha: 0.7)

        var instances: [NodeInstance] = []
        var outlines: [NodeInstance] = []

        for node in nodeCache {
            let radius = metrics.nodeRadius(for: node.weight)
            let isSelected = selectedNodeIDs.contains(node.id)
            let isHovered = hoveredNodeID == node.id
            let isMyNode = node.isMyNode
            let isInFocusNeighborhood = focusNeighborhoodIDs.isEmpty || focusNeighborhoodIDs.contains(node.id)
            let scale: CGFloat = isMyNode ? AnalyticsStyle.Graph.myNodeScale : 1.0
            let resolvedRadius = Float(radius * scale)
            let color: SIMD4<Float>
            if isSelected {
                color = selectedColor
            } else if isHovered {
                color = hoverColor
            } else if isMyNode {
                color = myNodeColor
            } else if node.isOfficial {
                color = officialNodeColor
            } else {
                color = baseColor
            }

            let finalColor: SIMD4<Float>
            if isInFocusNeighborhood || isSelected || isHovered || isMyNode {
                finalColor = color
            } else {
                finalColor = SIMD4(color.x, color.y, color.z, color.w * 0.28)
            }

            instances.append(NodeInstance(center: node.position, radius: resolvedRadius, color: finalColor))

            if isSelected || isHovered || isMyNode {
                let outlineScale: Float = isSelected ? 1.4 : 1.2
                let outline = NodeInstance(
                    center: node.position,
                    radius: resolvedRadius * outlineScale,
                    color: isMyNode ? myNodeOutline : outlineColor
                )
                outlines.append(outline)
            }
        }

        if instances.isEmpty {
            nodeInstanceBuffer = nil
        } else {
            nodeInstanceBuffer = device.makeBuffer(bytes: instances, length: instances.count * MemoryLayout<NodeInstance>.size, options: .storageModeShared)
        }
        if outlines.isEmpty {
            outlineInstanceBuffer = nil
        } else {
            outlineInstanceBuffer = device.makeBuffer(bytes: outlines, length: outlines.count * MemoryLayout<NodeInstance>.size, options: .storageModeShared)
        }
    }

    private func makeCircleVertexBuffer(device: MTLDevice) -> MTLBuffer? {
        let segments = 28
        var vertices: [CircleVertex] = []
        for i in 0..<segments {
            let angle1 = Float(i) / Float(segments) * Float.pi * 2
            let angle2 = Float(i + 1) / Float(segments) * Float.pi * 2
            let center = CircleVertex(position: SIMD2(0, 0))
            let v1 = CircleVertex(position: SIMD2(cos(angle1), sin(angle1)))
            let v2 = CircleVertex(position: SIMD2(cos(angle2), sin(angle2)))
            vertices.append(center)
            vertices.append(v1)
            vertices.append(v2)
        }
        return device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<CircleVertex>.size, options: .storageModeShared)
    }

    /// Points-to-pixels for the display this view is on.
    ///
    /// Falls back to the main display rather than 1.0: guessing low renders a
    /// blurry graph on every Retina screen, which is every screen this app
    /// runs on.
    private func backingScale(for view: MTKView) -> CGFloat {
        #if os(macOS)
        return view.window?.backingScaleFactor ?? MainActor.assumeIsolated { PlatformScreen.scale }
        #else
        return view.window?.screen.scale ?? MainActor.assumeIsolated { PlatformScreen.scale }
        #endif
    }

    private func requestRedraw() {
        guard let view else { return }
        view.setNeedsDisplay(view.bounds)
    }

    private func requestInteractionRedraw() {
        guard let view else { return }
        lastInteractionTime = CACurrentMediaTime()
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.setNeedsDisplay(view.bounds)
        // Notify SwiftUI of camera state changes for label overlay
        onCameraUpdate(CameraState(scale: camera.scale, offset: camera.offset))
    }

    private func hitTest(at point: CGPoint, in view: MTKView) -> (id: String, screenPoint: CGPoint)? {
        let backingScale = self.backingScale(for: view)
        let viewSizePixels = view.drawableSize
        let insetPixels = AnalyticsStyle.Layout.graphInset * backingScale
        let cameraOffsetPixels = CGSize(width: camera.offset.width * backingScale, height: camera.offset.height * backingScale)
        // View coords: origin bottom-left (AppKit default). Drawable: origin top-left. Flip Y.
        let hitPixel = CGPoint(x: point.x * backingScale, y: viewSizePixels.height - point.y * backingScale)

        var closest: (String, CGFloat, CGPoint)?
        for node in nodeCache {
            let centerPixel = GraphCoordinateMapper.normalizedToPixel(
                normalized: node.position,
                viewSizePixels: viewSizePixels,
                insetPixels: insetPixels,
                cameraScale: camera.scale,
                cameraOffsetPixels: cameraOffsetPixels
            )
            let nodeRadiusPixels = metrics.nodeRadius(for: node.weight) * camera.scale * backingScale
            let minHitPixels = AnalyticsStyle.Graph.minHitRadiusPoints * backingScale
            let hitRadiusPixels = max(minHitPixels, nodeRadiusPixels + 4)
            let distance = hypot(centerPixel.x - hitPixel.x, centerPixel.y - hitPixel.y)
            if distance <= hitRadiusPixels {
                if let existing = closest {
                    if distance < existing.1 {
                        closest = (node.id, distance, centerPixel)
                    }
                } else {
                    closest = (node.id, distance, centerPixel)
                }
            }
        }
        guard let closest else { return nil }
        let screenPointPoints = CGPoint(x: closest.2.x / backingScale, y: closest.2.y / backingScale)
        return (closest.0, screenPointPoints)
    }

    private func nodes(in rect: CGRect) -> Set<String> {
        guard let view else { return [] }
        let backingScale = self.backingScale(for: view)
        let viewSizePixels = view.drawableSize
        let insetPixels = AnalyticsStyle.Layout.graphInset * backingScale
        let cameraOffsetPixels = CGSize(width: camera.offset.width * backingScale, height: camera.offset.height * backingScale)
        // View rect: origin bottom-left (AppKit). Drawable: origin top-left. Flip Y so rect in drawable space.
        let pixelRect = CGRect(
            x: rect.origin.x * backingScale,
            y: viewSizePixels.height - (rect.origin.y + rect.height) * backingScale,
            width: rect.width * backingScale,
            height: rect.height * backingScale
        )
        var selected: Set<String> = []
        for node in nodeCache {
            let centerPixel = GraphCoordinateMapper.normalizedToPixel(
                normalized: node.position,
                viewSizePixels: viewSizePixels,
                insetPixels: insetPixels,
                cameraScale: camera.scale,
                cameraOffsetPixels: cameraOffsetPixels
            )
            if pixelRect.contains(centerPixel) {
                selected.insert(node.id)
            }
        }
        return selected
    }

    private func colorVector(_ color: PlatformColor, alpha: Float) -> SIMD4<Float> {
        let components = color.sRGBComponents
        return SIMD4(
            Float(components.red),
            Float(components.green),
            Float(components.blue),
            alpha
        )
    }
}

/// Lightweight key to avoid hashing full GraphModel / [NodePosition] on every update.
nonisolated private struct GraphRenderKey: Hashable {
    let nodeCount: Int
    let edgeCount: Int
    let modelChecksum: Int
    let myCallsign: String
    let positionsChecksum: Int
    let visibleNodeCount: Int
    let visibleNodesChecksum: Int

    static func from(
        model: GraphModel,
        positions: [NodePosition],
        myCallsign: String,
        visibleNodeIDs: Set<String> = []
    ) -> GraphRenderKey {
        // Include graph topology/content so renderer buffers are rebuilt whenever
        // logical graph data changes even if counts stay the same.
        var modelHasher = Hasher()
        for node in model.nodes.sorted(by: { $0.id < $1.id }) {
            node.id.hash(into: &modelHasher)
            node.callsign.hash(into: &modelHasher)
            node.weight.hash(into: &modelHasher)
            node.degree.hash(into: &modelHasher)
            node.isNetRomOfficial.hash(into: &modelHasher)
            node.inBytes.hash(into: &modelHasher)
            node.outBytes.hash(into: &modelHasher)
        }
        for edge in model.edges.sorted(by: {
            if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
            if $0.targetID != $1.targetID { return $0.targetID < $1.targetID }
            if $0.linkType != $1.linkType { return $0.linkType.renderPriority < $1.linkType.renderPriority }
            if $0.weight != $1.weight { return $0.weight < $1.weight }
            return ($0.isStale ? 1 : 0) < ($1.isStale ? 1 : 0)
        }) {
            edge.sourceID.hash(into: &modelHasher)
            edge.targetID.hash(into: &modelHasher)
            edge.linkType.hash(into: &modelHasher)
            edge.weight.hash(into: &modelHasher)
            edge.isStale.hash(into: &modelHasher)
        }

        var hasher = Hasher()
        for p in positions.sorted(by: { $0.id < $1.id }) {
            p.id.hash(into: &hasher)
            p.x.hash(into: &hasher)
            p.y.hash(into: &hasher)
        }
        // Hash visible node IDs for focus mode changes
        var visibleHasher = Hasher()
        for id in visibleNodeIDs.sorted() {
            id.hash(into: &visibleHasher)
        }
        return GraphRenderKey(
            nodeCount: model.nodes.count,
            edgeCount: model.edges.count,
            modelChecksum: modelHasher.finalize(),
            myCallsign: myCallsign,
            positionsChecksum: hasher.finalize(),
            visibleNodeCount: visibleNodeIDs.count,
            visibleNodesChecksum: visibleHasher.finalize()
        )
    }
}

nonisolated private struct GraphHighlightKey: Hashable {
    let selectedNodeIDs: Set<String>
    let hoveredNodeID: String?
}

nonisolated private struct GraphNodeInfo: Hashable {
    let id: String
    let callsign: String
    let position: SIMD2<Float>
    let weight: Int
    let isMyNode: Bool
    let isOfficial: Bool
}

nonisolated private struct GraphEdgeInfo: Hashable {
    let source: GraphNodeInfo
    let target: GraphNodeInfo
    let linkType: LinkType
    let weight: Int
    let isStale: Bool
}

nonisolated private struct GraphMetrics {
    let minNodeWeight: Int
    let maxNodeWeight: Int
    let maxEdgeWeight: Int

    func nodeRadius(for weight: Int) -> CGFloat {
        let logMin = log(Double(minNodeWeight))
        let logMax = log(Double(maxNodeWeight))
        let logValue = log(Double(max(weight, 1)))
        let t = logMax == logMin ? 0.5 : (logValue - logMin) / (logMax - logMin)
        let range = AnalyticsStyle.Graph.nodeRadiusRange
        return range.lowerBound + CGFloat(t) * (range.upperBound - range.lowerBound)
    }

    func edgeThickness(for weight: Int) -> CGFloat {
        let t = CGFloat(weight) / CGFloat(maxEdgeWeight)
        let range = AnalyticsStyle.Graph.edgeThicknessRange
        return range.lowerBound + t * (range.upperBound - range.lowerBound)
    }

    func edgeAlpha(for weight: Int) -> CGFloat {
        let t = CGFloat(weight) / CGFloat(maxEdgeWeight)
        let range = AnalyticsStyle.Graph.edgeAlphaRange
        let value = range.lowerBound + Double(t) * (range.upperBound - range.lowerBound)
        return CGFloat(value)
    }
}

nonisolated private struct GraphCamera {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    private var targetScale: CGFloat = 1
    private var targetOffset: CGSize = .zero

    /// Maximum pan distance from center (as fraction of view size at 1x).
    /// Kept tighter to prevent the graph from being panned mostly off-canvas.
    private static let baseMaxPanFraction: CGFloat = 0.28

    var isSettled: Bool {
        abs(scale - targetScale) < AnalyticsStyle.Graph.cameraSnapScaleEpsilon &&
        abs(offset.width - targetOffset.width) < AnalyticsStyle.Graph.cameraSnapOffsetEpsilon &&
        abs(offset.height - targetOffset.height) < AnalyticsStyle.Graph.cameraSnapOffsetEpsilon
    }

    mutating func reset() {
        scale = 1
        offset = .zero
        targetScale = 1
        targetOffset = .zero
    }

    mutating func pan(by delta: CGSize, viewSize: CGSize? = nil) {
        targetOffset.width += delta.width
        targetOffset.height += delta.height
        clampOffset(viewSize: viewSize)
    }

    /// Clamps target offset so the graph cannot be panned off-screen
    private mutating func clampOffset(viewSize: CGSize?) {
        guard let viewSize, viewSize.width > 0, viewSize.height > 0 else { return }
        // Allow modest panning at 1x, then expand allowance gradually when zoomed in.
        let effectiveScale = max(scale, targetScale)
        let zoomAllowance = max(1, sqrt(effectiveScale))
        let maxPanX = viewSize.width * Self.baseMaxPanFraction * zoomAllowance
        let maxPanY = viewSize.height * Self.baseMaxPanFraction * zoomAllowance
        targetOffset.width = targetOffset.width.clamped(to: -maxPanX...maxPanX)
        targetOffset.height = targetOffset.height.clamped(to: -maxPanY...maxPanY)
    }

    // `@MainActor` because it reads the view's bounds, and a view's bounds
    // are main-actor state. Zooming is a gesture response, so it is already
    // on the main actor when it runs.
    @MainActor
    mutating func zoom(at location: CGPoint, scaleDelta: CGFloat, view: MTKView?) {
        guard let view else { return }
        guard scaleDelta > 0 else { return }
        let zoomRange = AnalyticsStyle.Graph.zoomRange
        let newScale = (targetScale * scaleDelta).clamped(to: zoomRange)
        let viewSize = view.bounds.size
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let translated = CGPoint(x: location.x - center.x - targetOffset.width, y: location.y - center.y - targetOffset.height)
        let ratio = newScale / targetScale
        targetOffset.width = (targetOffset.width + translated.x) * ratio - translated.x
        targetOffset.height = (targetOffset.height + translated.y) * ratio - translated.y
        targetScale = newScale
        clampOffset(viewSize: viewSize)
    }

    mutating func focus(on normalized: SIMD2<Float>, size: CGSize) {
        targetScale = AnalyticsStyle.Graph.focusScale
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let inset = AnalyticsStyle.Layout.graphInset
        let width = max(1, size.width - inset * 2)
        let height = max(1, size.height - inset * 2)
        let base = CGPoint(
            x: inset + CGFloat(normalized.x) * width,
            y: inset + CGFloat(normalized.y) * height
        )
        targetOffset = CGSize(
            width: -(base.x - center.x) * targetScale,
            height: -(base.y - center.y) * targetScale
        )
    }

    /// Smoothly animates to zoom-to-fit (default framing showing all nodes)
    mutating func zoomToFit() {
        targetScale = 1.0
        targetOffset = .zero
    }

    /// Smoothly animates reset with configurable zoom
    mutating func animatedReset() {
        targetScale = 1.0
        targetOffset = .zero
    }

    /// Fits camera to a bounding box of nodes (in normalized 0-1 coordinates).
    /// Computes appropriate scale and offset to show all nodes with padding.
    ///
    /// - Parameters:
    ///   - bounds: Bounding box in normalized coordinates (minX, minY, maxX, maxY)
    ///   - viewSize: Current view size in points
    ///   - padding: Fraction of view to use as margin (default 0.1 = 10%)
    mutating func fitToBounds(
        minX: Double, minY: Double, maxX: Double, maxY: Double,
        viewSize: CGSize,
        padding: CGFloat = 0.1
    ) {
        let inset = AnalyticsStyle.Layout.graphInset
        let drawableWidth = max(1, viewSize.width - inset * 2)
        let drawableHeight = max(1, viewSize.height - inset * 2)

        // Handle single-point case
        let boundsWidth = max(0.01, maxX - minX)
        let boundsHeight = max(0.01, maxY - minY)

        // Compute center of bounds in normalized coords
        let centerX = (minX + maxX) / 2.0
        let centerY = (minY + maxY) / 2.0

        // Compute scale to fit bounds within view (with padding)
        let availableWidth = drawableWidth * (1 - 2 * padding)
        let availableHeight = drawableHeight * (1 - 2 * padding)
        let scaleX = availableWidth / (CGFloat(boundsWidth) * drawableWidth)
        let scaleY = availableHeight / (CGFloat(boundsHeight) * drawableHeight)
        let fitScale = min(scaleX, scaleY).clamped(to: AnalyticsStyle.Graph.zoomRange)

        // Compute offset to center the bounds
        let viewCenter = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let boundsScreenX = inset + CGFloat(centerX) * drawableWidth
        let boundsScreenY = inset + CGFloat(centerY) * drawableHeight

        targetScale = fitScale
        targetOffset = CGSize(
            width: -(boundsScreenX - viewCenter.x) * fitScale,
            height: -(boundsScreenY - viewCenter.y) * fitScale
        )
    }

    mutating func update(deltaTime: CFTimeInterval) -> Bool {
        _ = deltaTime
        let snapScale = AnalyticsStyle.Graph.cameraSnapScaleEpsilon
        let snapOffset = AnalyticsStyle.Graph.cameraSnapOffsetEpsilon
        let deadScale = AnalyticsStyle.Graph.cameraDeadZoneScale
        let deadOffset = AnalyticsStyle.Graph.cameraDeadZoneOffset

        if abs(scale - targetScale) < snapScale && abs(offset.width - targetOffset.width) < snapOffset && abs(offset.height - targetOffset.height) < snapOffset {
            scale = targetScale
            offset = targetOffset
            return false
        }

        let zoomSmoothing = AnalyticsStyle.Graph.zoomSmoothing
        let panSmoothing = AnalyticsStyle.Graph.panSmoothing
        var nextScale = scale + (targetScale - scale) * zoomSmoothing
        var nextOffsetWidth = offset.width + (targetOffset.width - offset.width) * panSmoothing
        var nextOffsetHeight = offset.height + (targetOffset.height - offset.height) * panSmoothing

        if abs(nextScale - targetScale) < deadScale { nextScale = targetScale }
        if abs(nextOffsetWidth - targetOffset.width) < deadOffset { nextOffsetWidth = targetOffset.width }
        if abs(nextOffsetHeight - targetOffset.height) < deadOffset { nextOffsetHeight = targetOffset.height }

        let changed = abs(nextScale - scale) > snapScale ||
            abs(nextOffsetWidth - offset.width) > snapOffset ||
            abs(nextOffsetHeight - offset.height) > snapOffset

        scale = nextScale
        offset = CGSize(width: nextOffsetWidth, height: nextOffsetHeight)
        return changed
    }
}

/// Canonical normalized [0,1] -> drawable pixel mapping; must match Metal toPixel exactly.
nonisolated private enum GraphCoordinateMapper {
    /// Converts normalized (x,y in [0,1]) to pixel coordinates in drawable space.
    /// Uses same formula as shader: base = inset + normalized * (size - inset*2); pixel = (base - center)*scale + center + offset.
    static func normalizedToPixel(
        normalized: SIMD2<Float>,
        viewSizePixels: CGSize,
        insetPixels: CGFloat,
        cameraScale: CGFloat,
        cameraOffsetPixels: CGSize
    ) -> CGPoint {
        let sx = viewSizePixels.width
        let sy = viewSizePixels.height
        let ix = insetPixels
        let iy = insetPixels
        let baseX = ix + CGFloat(normalized.x) * (sx - ix * 2)
        let baseY = iy + CGFloat(normalized.y) * (sy - iy * 2)
        let centerX = sx * 0.5
        let centerY = sy * 0.5
        let pixelX = (baseX - centerX) * cameraScale + centerX + cameraOffsetPixels.width
        let pixelY = (baseY - centerY) * cameraScale + centerY + cameraOffsetPixels.height
        return CGPoint(x: pixelX, y: pixelY)
    }
}

nonisolated private enum CallsignMatcher {
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func baseCallsign(_ value: String) -> String {
        normalize(value).split(separator: "-").first.map(String.init) ?? ""
    }

    static func matches(candidate: String, target: String) -> Bool {
        let targetBase = baseCallsign(target)
        guard !targetBase.isEmpty else { return false }
        return baseCallsign(candidate) == targetBase
    }
}

nonisolated private struct GraphUniforms {
    var viewSize: SIMD2<Float>
    var inset: SIMD2<Float>
    var offset: SIMD2<Float>
    var scale: Float
    var padding: Float = 0
}

nonisolated private struct CircleVertex {
    var position: SIMD2<Float>
}

nonisolated private struct NodeInstance {
    var center: SIMD2<Float>
    var radius: Float
    var color: SIMD4<Float>
}

nonisolated private struct EdgeInstance {
    var start: SIMD2<Float>
    var end: SIMD2<Float>
    var thickness: Float
    var color: SIMD4<Float>
}

// MARK: - Safe range (avoids invalid ClosedRange when lower > upper)
private extension ClosedRange where Bound: Comparable {
    /// Returns a valid ClosedRange; if lower > upper, bounds are normalized so the range is valid.
    static func safe(_ lower: Bound, _ upper: Bound) -> ClosedRange<Bound> {
        let (a, b) = lower <= upper ? (lower, upper) : (upper, lower)
        return a ... b
    }
}

private extension CGFloat {
    // See the Int version: pure arithmetic, explicitly nonisolated so the
    // renderer's value types can use it without crossing an actor.
    nonisolated func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        let (lo, hi) = range.lowerBound <= range.upperBound
            ? (range.lowerBound, range.upperBound)
            : (range.upperBound, range.lowerBound)
        return Swift.min(hi, Swift.max(lo, self))
    }
}
