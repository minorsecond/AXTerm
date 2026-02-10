//
//  AnalyticsStyle.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-01.
//

import AppKit
import SwiftUI

nonisolated enum AnalyticsStyle {
    enum Layout {
        static let pagePadding: CGFloat = 20
        static let sectionSpacing: CGFloat = 18
        static let cardCornerRadius: CGFloat = 12
        static let cardPadding: CGFloat = 14
        static let cardSpacing: CGFloat = 12
        static let chartHeight: CGFloat = 180
        static let heatmapHeight: CGFloat = 220
        static let graphHeight: CGFloat = 420
        static let inspectorWidth: CGFloat = 260
        static let graphInset: CGFloat = 24
        static let metricColumns: Int = 3
        static let chartColumns: Int = 2
    }

    enum Chart {
        static let axisLabelCount: Int = 5
        static let smoothLines: Bool = false
        static let showSymbols: Bool = false
        static let targetBucketPixelWidth: CGFloat = 28
    }

    enum Heatmap {
        static let minAlpha: Double = 0.08
        static let maxAlpha: Double = 0.6
        static let cellCornerRadius: CGFloat = 3
        static let labelPadding: CGFloat = 6
        static let labelWidth: CGFloat = 48
        static let labelHeight: CGFloat = 16
        static let labelStride: Int = 6
    }

    enum Histogram {
        static let binCount: Int = 10
        static let maxLabelCount: Int = 6
    }

    enum Graph {
        static let maxNodesDefault: Int = 150
        static let minNodes: Int = 25
        static let layoutIterationsPerTick: Int = 2
        static let layoutCooling: Double = 0.92
        static let layoutTimeStep: Double = 0.018
        static let layoutEnergyThreshold: Double = 0.00001
        static let layoutPublishThreshold: Double = 0.0005
        static let repulsionStrength: Double = 0.015
        static let springStrength: Double = 0.12
        static let springLength: Double = 0.18
        static let nodeRadiusRange: ClosedRange<CGFloat> = 4...12
        static let nodeHitRadius: CGFloat = 22
        /// Minimum hit radius in points so "my node" and small nodes are always clickable.
        static let minHitRadiusPoints: CGFloat = 14
        /// Drag below this (points) is treated as a click.
        static let dragThresholdPoints: CGFloat = 6
        static let edgeThicknessRange: ClosedRange<CGFloat> = 0.8...2.6
        static let edgeAlphaRange: ClosedRange<Double> = 0.2...0.8
        static let selectionGlowWidth: CGFloat = 4
        static let zoomRange: ClosedRange<CGFloat> = 0.4...2.5
        static let focusScale: CGFloat = 1.4
        static let panDamping: CGFloat = 0.9
        static let zoomSmoothing: Double = 0.18
        static let panSmoothing: Double = 0.2
        /// When within this of target, snap and stop animating.
        static let cameraSnapScaleEpsilon: CGFloat = 0.0005
        static let cameraSnapOffsetEpsilon: CGFloat = 0.3
        /// Ignore target changes smaller than this (avoids float jitter).
        static let cameraDeadZoneScale: CGFloat = 0.0002
        static let cameraDeadZoneOffset: CGFloat = 0.2
        static let hoverEdgeAlpha: Double = 0.7
        static let myNodeScale: CGFloat = 1.15
    }

    enum Tables {
        static let topLimit: Int = 6
    }

    enum Colors {
        static let cardBackground = Color(nsColor: .controlBackgroundColor)
        static let cardStroke = Color(nsColor: .separatorColor)
        static let divider = Color(nsColor: .separatorColor)
        static let textSecondary = Color(nsColor: .secondaryLabelColor)
        static let accent = Color(nsColor: .controlAccentColor)
        static let graphMyNode = Color(nsColor: .systemPurple)
        static let chartGridLine = Color(nsColor: .separatorColor).opacity(0.35)
        static let chartAxis = Color(nsColor: .secondaryLabelColor)
        static let chartPlotBackground = Color.clear

        static func accent(alpha: Double) -> Color {
            Color(nsColor: NSColor.controlAccentColor.withAlphaComponent(alpha))
        }

        static let neutralFill = Color(nsColor: .secondaryLabelColor).opacity(0.12)
        static let graphEdge = Color(nsColor: .secondaryLabelColor).opacity(0.55)
        static let graphNode = Color(nsColor: .labelColor)
        static let graphNodeMuted = Color(nsColor: .secondaryLabelColor)
        static let graphOfficialNode = Color(nsColor: .systemOrange)
    }
}
