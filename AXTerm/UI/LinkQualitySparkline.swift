import SwiftUI

/// Link quality over time, drawn small enough to sit inside a row.
///
/// Deliberately not a full chart: no axes, no legend, no interaction. The
/// question it answers is "has this changed", and a shape answers that faster
/// than numbers do. The precise values are in the row above it.
struct LinkQualitySparkline: View {

    let samples: [LinkQualityHistorySample]
    var tint: Color = .accentColor

    /// NET/ROM quality is a 0–255 scale, and drawing it against its own
    /// min/max would make a flat link look dramatic. The full scale keeps
    /// "barely moved" looking like barely moved.
    private let scale: Double = 255

    var body: some View {
        GeometryReader { geometry in
            let points = points(in: geometry.size)
            ZStack {
                if points.count >= 2 {
                    // Filled area first, so the line reads on top of it.
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x,
                                                 y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(tint.opacity(0.18))

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5,
                                                     lineCap: .round,
                                                     lineJoin: .round))
                }
            }
        }
        .accessibilityLabel("Link quality history")
        .accessibilityValue(accessibilitySummary)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard samples.count >= 2, size.width > 0, size.height > 0 else { return [] }
        // Spaced by time, not by index: a gap where the station was not heard
        // is real information, and evenly spacing the samples would hide it.
        let start = samples[0].sampledAt.timeIntervalSince1970
        let end = samples[samples.count - 1].sampledAt.timeIntervalSince1970
        let span = max(end - start, 1)

        return samples.map { sample in
            let x = (sample.sampledAt.timeIntervalSince1970 - start) / span * size.width
            let normalized = min(max(Double(sample.quality) / scale, 0), 1)
            // Inset by a point so a full-scale sample is not clipped.
            let y = size.height - 1 - normalized * (size.height - 2)
            return CGPoint(x: x, y: y)
        }
    }

    private var accessibilitySummary: String {
        guard let first = samples.first, let last = samples.last else { return "No history" }
        return "From \(first.quality) to \(last.quality) out of 255 over \(samples.count) samples"
    }
}
