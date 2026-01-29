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
    let onSelect: (String, Bool) -> Void
    let onSelectMany: (Set<String>, Bool) -> Void
    let onClearSelection: () -> Void
    let onHover: (String?) -> Void
    let onFocusHandled: () -> Void

    @State private var selectionRect: CGRect?
    @State private var hoverPoint: CGPoint?
    @State private var hoverNodeID: String?

    var body: some View {
        ZStack {
            GraphMetalViewRepresentable(
                graphModel: graphModel,
                nodePositions: nodePositions,
                selectedNodeIDs: selectedNodeIDs,
                hoveredNodeID: hoveredNodeID,
                myCallsign: myCallsign,
                resetToken: resetToken,
                focusNodeID: focusNodeID,
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
                onFocusHandled: onFocusHandled
            )

            if let selectionRect {
                SelectionRectView(rect: selectionRect)
            }

            if let hoverNodeID,
               let hoverPoint,
               let node = graphModel.nodes.first(where: { $0.id == hoverNodeID }) {
                GraphTooltipView(node: node)
                    .position(x: hoverPoint.x + 12, y: hoverPoint.y - 12)
            }
        }
        .background(AnalyticsStyle.Colors.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsStyle.Layout.cardCornerRadius))
        .focusable()
        .onExitCommand {
            onClearSelection()
        }
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
    let onSelect: (String, Bool) -> Void
    let onSelectMany: (Set<String>, Bool) -> Void
    let onClearSelection: () -> Void
    let onHover: (String?, CGPoint?) -> Void
    let onSelectionRect: (CGRect?) -> Void
    let onFocusHandled: () -> Void

    func makeCoordinator() -> GraphMetalCoordinator {
        GraphMetalCoordinator(
            onSelect: onSelect,
            onSelectMany: onSelectMany,
            onClearSelection: onClearSelection,
            onHover: onHover,
            onSelectionRect: onSelectionRect,
            onFocusHandled: onFocusHandled
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
            myCallsign: myCallsign
        )

        context.coordinator.handle(resetToken: resetToken)
        context.coordinator.handle(focusNodeID: focusNodeID)
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
        interactionDelegate?.handleMouseDown(location: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

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
        interactionDelegate?.handleScroll(
            location: convert(event.locationInWindow, from: nil),
            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            modifiers: event.modifierFlags
        )
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
    func handleScroll(location: CGPoint, delta: CGSize, modifiers: NSEvent.ModifierFlags)
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

    init(
        onSelect: @escaping (String, Bool) -> Void,
        onSelectMany: @escaping (Set<String>, Bool) -> Void,
        onClearSelection: @escaping () -> Void,
        onHover: @escaping (String?, CGPoint?) -> Void,
        onSelectionRect: @escaping (CGRect?) -> Void,
        onFocusHandled: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onSelectMany = onSelectMany
        self.onClearSelection = onClearSelection
        self.onHover = onHover
        self.onSelectionRect = onSelectionRect
        self.onFocusHandled = onFocusHandled
        super.init()
    }

    func attach(view: GraphMetalView) {
        self.view = view
        view.delegate = self
        setupMetal(in: view)
    }

    func update(
        graphModel: GraphModel,
        nodePositions: [NodePosition],
        selectedNodeIDs: Set<String>,
        hoveredNodeID: String?,
        myCallsign: String
    ) {
        let normalizedCallsign = CallsignMatcher.normalize(myCallsign)
        let newKey = GraphRenderKey.from(model: graphModel, positions: nodePositions, myCallsign: normalizedCallsign)
        let graphChanged = newKey != graphKey
        if graphChanged {
            graphKey = newKey
            rebuildGraphBuffers(model: graphModel, positions: nodePositions, myCallsign: normalizedCallsign)
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
            camera.pan(by: delta)
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
                    camera.reset()
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

    func handleScroll(location: CGPoint, delta: CGSize, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.contains(.command) else {
            camera.pan(by: CGSize(width: -delta.width, height: -delta.height))
            requestInteractionRedraw()
            return
        }
        let zoomDelta = 1 - (delta.height * 0.002)
        camera.zoom(at: location, scaleDelta: zoomDelta, view: view)
        requestInteractionRedraw()
    }

    func handleMagnify(magnification: CGFloat, location: CGPoint) {
        let zoomDelta = 1 + (magnification * 0.6)
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

    private func rebuildGraphBuffers(model: GraphModel, positions: [NodePosition], myCallsign: String) {
        nodeCache.removeAll()
        edgeCache.removeAll()
        nodeIndex.removeAll()

        let positionMap = Dictionary(uniqueKeysWithValues: positions.map { ($0.id, $0) })
        let weights = model.nodes.map { $0.weight }
        metrics = GraphMetrics(
            minNodeWeight: max(1, weights.min() ?? 1),
            maxNodeWeight: max(1, weights.max() ?? 1),
            maxEdgeWeight: max(1, model.edges.map { $0.weight }.max() ?? 1)
        )

        for node in model.nodes {
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

        for edge in model.edges {
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
    }

    private func hitTest(at point: CGPoint, in view: MTKView) -> (id: String, screenPoint: CGPoint)? {
        let backingScale = self.backingScale(for: view)
        let viewSizePixels = view.drawableSize
        let insetPixels = AnalyticsStyle.Layout.graphInset * backingScale
        let cameraOffsetPixels = CGSize(width: camera.offset.width * backingScale, height: camera.offset.height * backingScale)
        let hitPixel = CGPoint(x: point.x * backingScale, y: point.y * backingScale)

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
        let pixelRect = CGRect(
            x: rect.origin.x * backingScale,
            y: rect.origin.y * backingScale,
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

    static func from(model: GraphModel, positions: [NodePosition], myCallsign: String) -> GraphRenderKey {
        var hasher = Hasher()
        for p in positions.sorted(by: { $0.id < $1.id }) {
            p.id.hash(into: &hasher)
            p.x.hash(into: &hasher)
            p.y.hash(into: &hasher)
        }
        return GraphRenderKey(
            nodeCount: model.nodes.count,
            edgeCount: model.edges.count,
            myCallsign: myCallsign,
            positionsChecksum: hasher.finalize()
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

    mutating func pan(by delta: CGSize) {
        targetOffset.width += delta.width
        targetOffset.height += delta.height
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
