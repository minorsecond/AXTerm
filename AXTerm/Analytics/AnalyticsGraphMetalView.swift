//
//  AnalyticsGraphMetalView.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-20.
//

import AppKit
import MetalKit
import SwiftUI

struct AnalyticsGraphView: View {
    let graphModel: GraphModel
    let nodePositions: [NodePosition]
    let selectedNodeIDs: Set<String>
    let hoveredNodeID: String?
    let myCallsign: String
    let resetToken: UUID
    let focusNodeID: String?
    let fitToSelectionRequest: UUID?
    let resetCameraRequest: UUID?
    /// When focus mode is enabled, only render nodes in this set. Empty = show all.
    let visibleNodeIDs: Set<String>
    let onSelect: (String, Bool) -> Void
    let onSelectMany: (Set<String>, Bool) -> Void
    let onClearSelection: () -> Void
    let onHover: (String?) -> Void
    let onFocusHandled: () -> Void

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
                    resetCameraRequest: resetCameraRequest,
                    visibleNodeIDs: visibleNodeIDs,
                    onSelect: onSelect,
                    onSelectMany: onSelectMany,
                    onClearSelection: onClearSelection,
                    onHover: { nodeID, position in
                        hoverNodeID = nodeID
                        hoverPoint = position
                        onHover(nodeID)
                    },
                    onSelectionRect: { rect in
                        selectionRect = rect
                    },
                    onFocusHandled: onFocusHandled,
                    onCameraUpdate: { newState in
                        cameraState = newState
                    }
                )

                if let selectionRect {
                    let h = geometry.size.height
                    let flipped = CGRect(x: selectionRect.minX, y: h - selectionRect.maxY, width: selectionRect.width, height: selectionRect.height)
                    SelectionRectView(rect: flipped)
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
                        viewSize: geometry.size,
                        cameraState: cameraState
                    )
                    GraphTooltipView(node: node)
                        .position(tooltipPosition)
                }
            }
        }
        .background(AnalyticsStyle.Colors.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius))
        .focusable(interactions: [])  // Disable focus-driven scrolling but keep keyboard handling via NSView
        .onExitCommand {
            onClearSelection()
        }
    }

    /// Calculates the optimal tooltip position near a node, avoiding edges.
    /// Uses the same coordinate transformation as normalizedToScreen for accurate placement.
    private static func calculateTooltipPosition(
        nodePos: NodePosition,
        viewSize: CGSize,
        cameraState: CameraState
    ) -> CGPoint {
        let inset = AnalyticsStyle.Layout.graphInset
        let width = max(1, viewSize.width - inset * 2)
        let height = max(1, viewSize.height - inset * 2)

        // Use exact same formula as normalizedToScreen for node position
        let base = CGPoint(
            x: inset + nodePos.x * width,
            y: inset + nodePos.y * height
        )
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let screenX = (base.x - center.x) * cameraState.scale + center.x + cameraState.offset.width
        let screenY = (base.y - center.y) * cameraState.scale + center.y + cameraState.offset.height

        // Tooltip sizing - keep compact
        let tooltipWidth: CGFloat = 100
        let tooltipHeight: CGFloat = 55
        let tooltipGap: CGFloat = 4  // Minimal gap from node edge

        // Use a small fixed offset from node center (just enough to clear the node)
        let nodeOffset: CGFloat = 8 * cameraState.scale + tooltipGap

        // Smart positioning: prefer upper-right, but adjust to stay in bounds
        let margin: CGFloat = 6

        // Calculate available space in each direction
        let spaceRight = viewSize.width - screenX - margin
        let spaceLeft = screenX - margin
        let spaceTop = screenY - margin
        let spaceBottom = viewSize.height - screenY - margin

        // Determine horizontal position - position tooltip edge near node, not center
        let tooltipX: CGFloat
        if spaceRight >= nodeOffset + tooltipWidth / 2 {
            // Place to the right: tooltip's left edge near node
            tooltipX = screenX + nodeOffset + tooltipWidth / 2
        } else if spaceLeft >= nodeOffset + tooltipWidth / 2 {
            // Place to the left: tooltip's right edge near node
            tooltipX = screenX - nodeOffset - tooltipWidth / 2
        } else {
            // Centered horizontally when no room on sides
            tooltipX = min(max(tooltipWidth / 2 + margin, screenX), viewSize.width - tooltipWidth / 2 - margin)
        }

        // Determine vertical position - position tooltip edge near node
        let tooltipY: CGFloat
        if spaceTop >= nodeOffset + tooltipHeight / 2 {
            // Place above: tooltip's bottom edge near node
            tooltipY = screenY - nodeOffset - tooltipHeight / 2
        } else if spaceBottom >= nodeOffset + tooltipHeight / 2 {
            // Place below: tooltip's top edge near node
            tooltipY = screenY + nodeOffset + tooltipHeight / 2
        } else {
            // Centered vertically when no room above/below
            tooltipY = min(max(tooltipHeight / 2 + margin, screenY), viewSize.height - tooltipHeight / 2 - margin)
        }

        return CGPoint(x: tooltipX, y: tooltipY)
    }
}

/// Lightweight state for camera position used by label overlay.
struct CameraState: Equatable {
    var scale: CGFloat
    var offset: CGSize
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
    /// When focus mode is enabled, only render labels for nodes in this set. Empty = show all.
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

            // Filter nodes if focus mode is active
            let displayNodes = visibleNodeIDs.isEmpty
                ? graphModel.nodes
                : graphModel.nodes.filter { visibleNodeIDs.contains($0.id) }

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

            for node in sortedNodes.prefix(maxLabels) {
                guard let position = positionMap[node.id] else { continue }
                guard CallsignValidator.isValidCallsign(node.callsign) else { continue }

                let suffix = CallsignValidator.extractSuffix(node.callsign)

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
                let isMyNode = CallsignMatcher.matches(candidate: node.callsign, target: normalizedCallsign)

                let font = Font.system(size: fontSize, weight: isSelected || isHovered ? .semibold : .regular)
                var text = Text(suffix).font(font)

                if isSelected {
                    text = text.foregroundColor(Color(nsColor: .controlAccentColor))
                } else if isHovered {
                    text = text.foregroundColor(Color(nsColor: .labelColor))
                } else if isMyNode {
                    text = text.foregroundColor(Color(nsColor: .systemPurple))
                } else {
                    text = text.foregroundColor(Color(nsColor: .secondaryLabelColor))
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

private struct GraphMetalViewRepresentable: NSViewRepresentable {
    let graphModel: GraphModel
    let nodePositions: [NodePosition]
    let selectedNodeIDs: Set<String>
    let hoveredNodeID: String?
    let myCallsign: String
    let resetToken: UUID
    let focusNodeID: String?
    let fitToSelectionRequest: UUID?
    let resetCameraRequest: UUID?
    let visibleNodeIDs: Set<String>
    let onSelect: (String, Bool) -> Void
    let onSelectMany: (Set<String>, Bool) -> Void
    let onClearSelection: () -> Void
    let onHover: (String?, CGPoint?) -> Void
    let onSelectionRect: (CGRect?) -> Void
    let onFocusHandled: () -> Void
    let onCameraUpdate: (CameraState) -> Void

    func makeCoordinator() -> GraphMetalCoordinator {
        GraphMetalCoordinator(
            onSelect: onSelect,
            onSelectMany: onSelectMany,
            onClearSelection: onClearSelection,
            onHover: onHover,
            onSelectionRect: onSelectionRect,
            onFocusHandled: onFocusHandled,
            onCameraUpdate: onCameraUpdate
        )
    }

    func makeNSView(context: Context) -> GraphMetalView {
        let view = GraphMetalView()
        view.interactionDelegate = context.coordinator
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: GraphMetalView, context: Context) {
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
            visibleNodeIDs: visibleNodeIDs,
            nodePositions: nodePositions
        )
        context.coordinator.handle(resetCameraRequest: resetCameraRequest)
    }
}

private struct SelectionRectView: View {
    let rect: CGRect

    var body: some View {
        Rectangle()
            .strokeBorder(Color(nsColor: .selectedControlColor).opacity(0.7), lineWidth: 1)
            .background(Color(nsColor: .selectedControlColor).opacity(0.12))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

private struct GraphTooltipView: View {
    let node: NetworkGraphNode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.callsign)
                .font(.caption.weight(.semibold))
            Text("Packets: \(node.weight)")
                .font(.caption2)
            Text("Bytes: \((node.inBytes + node.outBytes).formatted())")
                .font(.caption2)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 2)
        )
    }
}

private final class GraphMetalView: MTKView {
    weak var interactionDelegate: GraphMetalInteractionDelegate?

    private var trackingArea: NSTrackingArea?
    private var magnifyRecognizer: NSMagnificationGestureRecognizer?

    override var acceptsFirstResponder: Bool { true }

    /// Prevent the scroll view from scrolling when this view becomes first responder
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        // Do nothing - we don't want clicks on the graph to scroll the page
        return false
    }

    init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        enableSetNeedsDisplay = true
        isPaused = true
        framebufferOnly = true
        // Opaque clear so we never show black; matches card background in light/dark mode.
        let bg = NSColor.controlBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.controlBackgroundColor
        clearColor = MTLClearColor(
            red: Double(bg.redComponent),
            green: Double(bg.greenComponent),
            blue: Double(bg.blueComponent),
            alpha: 1
        )
        // isOpaque is read-only on NSView; opaque clearColor above avoids black background.
        colorPixelFormat = .bgra8Unorm
        sampleCount = 4
        preferredFramesPerSecond = 60
        setupGestures()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupGestures() {
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
        interactionDelegate?.handleMouseDown(location: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    /// Prevent NSClipView/NSScrollView from scrolling when we become first responder
    override var needsPanelToBecomeKey: Bool { false }

    override func mouseDragged(with event: NSEvent) {
        interactionDelegate?.handleMouseDragged(location: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        interactionDelegate?.handleMouseUp(
            location: convert(event.locationInWindow, from: nil),
            modifiers: event.modifierFlags,
            clickCount: event.clickCount
        )
    }

    override func scrollWheel(with event: NSEvent) {
        // Detect if this is a trackpad scroll (momentum or precise) vs mouse wheel
        let isTrackpad = event.hasPreciseScrollingDeltas || event.momentumPhase != []
        let consumed = interactionDelegate?.handleScroll(
            location: convert(event.locationInWindow, from: nil),
            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            modifiers: event.modifierFlags,
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
}

private protocol GraphMetalInteractionDelegate: AnyObject {
    func handleMouseMoved(location: CGPoint)
    func handleMouseExited()
    func handleMouseDown(location: CGPoint, modifiers: NSEvent.ModifierFlags)
    func handleMouseDragged(location: CGPoint, modifiers: NSEvent.ModifierFlags)
    func handleMouseUp(location: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int)
    /// Returns true if the scroll was consumed (graph panned/zoomed), false to pass through to parent
    func handleScroll(location: CGPoint, delta: CGSize, modifiers: NSEvent.ModifierFlags, isTrackpad: Bool) -> Bool
    func handleMagnify(magnification: CGFloat, location: CGPoint)
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
    private let onCameraUpdate: (CameraState) -> Void

    init(
        onSelect: @escaping (String, Bool) -> Void,
        onSelectMany: @escaping (Set<String>, Bool) -> Void,
        onClearSelection: @escaping () -> Void,
        onHover: @escaping (String?, CGPoint?) -> Void,
        onSelectionRect: @escaping (CGRect?) -> Void,
        onFocusHandled: @escaping () -> Void,
        onCameraUpdate: @escaping (CameraState) -> Void
    ) {
        self.onSelect = onSelect
        self.onSelectMany = onSelectMany
        self.onClearSelection = onClearSelection
        self.onHover = onHover
        self.onSelectionRect = onSelectionRect
        self.onFocusHandled = onFocusHandled
        self.onCameraUpdate = onCameraUpdate
        super.init()
    }

    func attach(view: GraphMetalView) {
        self.view = view
        view.delegate = self
        setupMetal(in: view)
        // Notify initial camera state
        onCameraUpdate(CameraState(scale: camera.scale, offset: camera.offset))
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
        visibleNodeIDs: Set<String>,
        nodePositions: [NodePosition]
    ) {
        guard fitToSelectionRequest != lastFitToSelectionRequest else { return }
        lastFitToSelectionRequest = fitToSelectionRequest
        guard fitToSelectionRequest != nil, let view else { return }

        // Fit to all visible nodes (respecting focus filter)
        // If visibleNodeIDs is empty, fall back to all nodes
        let targetNodeIDs = visibleNodeIDs.isEmpty
            ? Set(nodePositions.map { $0.id })
            : visibleNodeIDs

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

        if currentTime - lastInteractionTime > 0.25, camera.isSettled {
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

    func handleMouseDown(location: CGPoint, modifiers: NSEvent.ModifierFlags) {
        selectionStart = location
        lastDragLocation = location
        accumulatedDrag = .zero
        isShiftSelecting = modifiers.contains(.shift)
        if isShiftSelecting {
            selectionRect = CGRect(origin: location, size: .zero)
            onSelectionRect(selectionRect)
        }
    }

    func handleMouseDragged(location: CGPoint, modifiers: NSEvent.ModifierFlags) {
        _ = modifiers
        guard let selectionStart else { return }
        let previous = lastDragLocation ?? selectionStart
        let delta = CGSize(width: location.x - previous.x, height: location.y - previous.y)
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

    func handleMouseUp(location: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
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

    func handleScroll(location: CGPoint, delta: CGSize, modifiers: NSEvent.ModifierFlags, isTrackpad: Bool) -> Bool {
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
        }
    }

    private func rebuildGraphBuffers(
        model: GraphModel,
        positions: [NodePosition],
        myCallsign: String,
        visibleNodeIDs: Set<String>
    ) {
        nodeCache.removeAll()
        edgeCache.removeAll()
        nodeIndex.removeAll()

        let positionMap = Dictionary(uniqueKeysWithValues: positions.map { ($0.id, $0) })

        // Determine which nodes to render (all if visibleNodeIDs is empty, otherwise filtered)
        let shouldFilter = !visibleNodeIDs.isEmpty
        let filteredNodes = shouldFilter
            ? model.nodes.filter { visibleNodeIDs.contains($0.id) }
            : model.nodes

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
                isMyNode: isMyNode
            )
            nodeCache.append(info)
            nodeIndex[node.id] = info
        }

        // Filter edges: only include edges where both endpoints are visible
        let filteredEdges = shouldFilter
            ? model.edges.filter { visibleNodeIDs.contains($0.sourceID) && visibleNodeIDs.contains($0.targetID) }
            : model.edges

        for edge in filteredEdges {
            guard let source = nodeIndex[edge.sourceID],
                  let target = nodeIndex[edge.targetID] else { continue }
            let info = GraphEdgeInfo(
                source: source,
                target: target,
                weight: edge.weight
            )
            edgeCache.append(info)
        }

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
            let alpha = metrics.edgeAlpha(for: edge.weight)
            let baseColor = colorVector(.secondaryLabelColor, alpha: Float(alpha))
            let thickness = metrics.edgeThickness(for: edge.weight)
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
            let alpha = max(metrics.edgeAlpha(for: edge.weight), CGFloat(AnalyticsStyle.Graph.hoverEdgeAlpha))
            let color = colorVector(.controlAccentColor, alpha: Float(alpha))
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
        let baseColor = colorVector(.secondaryLabelColor, alpha: 0.9)
        let hoverColor = colorVector(.labelColor, alpha: 1.0)
        let selectedColor = colorVector(.controlAccentColor, alpha: 1.0)
        let myNodeColor = colorVector(.systemPurple, alpha: 1.0)
        let outlineColor = colorVector(.controlAccentColor, alpha: 0.55)
        let myNodeOutline = colorVector(.systemPurple, alpha: 0.7)

        var instances: [NodeInstance] = []
        var outlines: [NodeInstance] = []

        for node in nodeCache {
            let radius = metrics.nodeRadius(for: node.weight)
            let isSelected = selectedNodeIDs.contains(node.id)
            let isHovered = hoveredNodeID == node.id
            let isMyNode = node.isMyNode
            let scale: CGFloat = isMyNode ? AnalyticsStyle.Graph.myNodeScale : 1.0
            let resolvedRadius = Float(radius * scale)
            let color: SIMD4<Float>
            if isSelected {
                color = selectedColor
            } else if isHovered {
                color = hoverColor
            } else if isMyNode {
                color = myNodeColor
            } else {
                color = baseColor
            }

            instances.append(NodeInstance(center: node.position, radius: resolvedRadius, color: color))

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

    private func backingScale(for view: MTKView) -> CGFloat {
        view.window?.backingScaleFactor ?? 1.0
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

    private func colorVector(_ color: NSColor, alpha: Float) -> SIMD4<Float> {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return SIMD4(
            Float(converted.redComponent),
            Float(converted.greenComponent),
            Float(converted.blueComponent),
            alpha
        )
    }
}

/// Lightweight key to avoid hashing full GraphModel / [NodePosition] on every update.
private struct GraphRenderKey: Hashable {
    let nodeCount: Int
    let edgeCount: Int
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
            myCallsign: myCallsign,
            positionsChecksum: hasher.finalize(),
            visibleNodeCount: visibleNodeIDs.count,
            visibleNodesChecksum: visibleHasher.finalize()
        )
    }
}

private struct GraphHighlightKey: Hashable {
    let selectedNodeIDs: Set<String>
    let hoveredNodeID: String?
}

private struct GraphNodeInfo: Hashable {
    let id: String
    let callsign: String
    let position: SIMD2<Float>
    let weight: Int
    let isMyNode: Bool
}

private struct GraphEdgeInfo: Hashable {
    let source: GraphNodeInfo
    let target: GraphNodeInfo
    let weight: Int
}

private struct GraphMetrics {
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

private struct GraphCamera {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    private var targetScale: CGFloat = 1
    private var targetOffset: CGSize = .zero

    /// Maximum pan distance from center (as fraction of view size)
    private static let maxPanFraction: CGFloat = 0.6

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
        // Allow panning up to maxPanFraction of view size in any direction
        // Scale the limit inversely with zoom - when zoomed out, allow less panning
        let effectiveScale = max(scale, targetScale)
        let maxPanX = viewSize.width * Self.maxPanFraction * effectiveScale
        let maxPanY = viewSize.height * Self.maxPanFraction * effectiveScale
        targetOffset.width = targetOffset.width.clamped(to: -maxPanX...maxPanX)
        targetOffset.height = targetOffset.height.clamped(to: -maxPanY...maxPanY)
    }

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
private enum GraphCoordinateMapper {
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

private enum CallsignMatcher {
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

private struct GraphUniforms {
    var viewSize: SIMD2<Float>
    var inset: SIMD2<Float>
    var offset: SIMD2<Float>
    var scale: Float
    var padding: Float = 0
}

private struct CircleVertex {
    var position: SIMD2<Float>
}

private struct NodeInstance {
    var center: SIMD2<Float>
    var radius: Float
    var color: SIMD4<Float>
}

private struct EdgeInstance {
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
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        let (lo, hi) = range.lowerBound <= range.upperBound
            ? (range.lowerBound, range.upperBound)
            : (range.upperBound, range.lowerBound)
        return Swift.min(hi, Swift.max(lo, self))
    }
}
