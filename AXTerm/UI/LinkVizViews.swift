import SwiftUI
import Charts

// MARK: - Sliding-window ring

/// The AX.25 modulo-8 window as a ring: eight sequence slots, the receive
/// cursor V(R), and our own in-flight frames V(A)→V(S) highlighted. REJ and
/// timeout markers flash briefly via the parent's data.
struct WindowRingView: View {
    let snapshot: LinkWindowSnapshot?

    var body: some View {
        VStack(spacing: 2) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 10
                guard radius > 8 else { return }
                // Slot digits need room between the dot ring and the center;
                // below this they collide with everything and say nothing.
                // (The exchange console renders at ~45 pt radius — dots only.)
                let showDigits = radius >= 56

                for slot in 0..<8 {
                    // 12-o'clock start, clockwise
                    let angle = Angle(degrees: Double(slot) * 45 - 90)
                    let point = CGPoint(
                        x: center.x + Foundation.cos(angle.radians) * radius,
                        y: center.y + Foundation.sin(angle.radians) * radius)

                    var fill = Color.secondary.opacity(0.18)
                    var stroke = Color.secondary.opacity(0.35)
                    var slotRadius = max(5, radius * 0.16)

                    if let snap = snapshot {
                        if snap.sendBufferSeq.contains(slot) {
                            fill = .blue                         // our frame in flight
                            stroke = .blue
                            slotRadius *= 1.25
                        }
                        if slot == snap.vr {
                            stroke = .green                      // next expected from peer
                            slotRadius = max(slotRadius, radius * 0.2)
                        }
                    }

                    let rect = CGRect(
                        x: point.x - slotRadius, y: point.y - slotRadius,
                        width: slotRadius * 2, height: slotRadius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(fill))
                    context.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: slot == snapshot?.vr ? 2 : 1)

                    if showDigits {
                        context.draw(
                            Text("\(slot)").font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary),
                            at: CGPoint(
                                x: center.x + Foundation.cos(angle.radians) * (radius - 16),
                                y: center.y + Foundation.sin(angle.radians) * (radius - 16)))
                    }
                }

                if let snap = snapshot, radius >= 20 {
                    context.draw(
                        Text("\(snap.outstanding)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(snap.outstanding > 0 ? Color.blue : Color.secondary),
                        at: CGPoint(x: center.x, y: center.y - 5))
                    context.draw(
                        Text("in flight")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: center.x, y: center.y + 7))
                }
            }
            if let snap = snapshot {
                Text("K=\(snap.windowSize) · next rx \(snap.vr)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help("The AX.25 modulo-8 sequence window, slots 0–7 clockwise from the top. Blue dots are our I-frames still waiting for the peer's acknowledgment; the green ring marks V(R), the sequence number we expect from the peer next. The center counts frames in flight against the window size K.")
        .accessibilityLabel("Sliding window ring")
    }
}

// MARK: - RTT / RTO chart

struct RTTChartView: View {
    let samples: [LinkSessionViz.RTTSample]

    var body: some View {
        Chart {
            ForEach(samples) { s in
                AreaMark(
                    x: .value("Time", s.date),
                    yStart: .value("low", max(0, s.srtt - s.rttvar)),
                    yEnd: .value("high", s.srtt + s.rttvar))
                    .foregroundStyle(.blue.opacity(0.15))
                LineMark(x: .value("Time", s.date), y: .value("SRTT", s.srtt))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(x: .value("Time", s.date), y: .value("RTO", s.rto))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartYAxisLabel("seconds")
        .chartLegend(.hidden)
        .sessionTimeAxis(start: samples.first?.date, end: samples.last?.date)
    }
}

extension RTTChartView {
    /// Drawn beside the chart by the panel, so the plot keeps its height.
    static let legend: [ChartLegend.Item] = [
        .init(swatch: .line(.blue), label: "SRTT",
              help: "Smoothed round-trip time, with the ±RTTVAR band shaded behind it."),
        .init(swatch: .dashedLine(.orange), label: "RTO",
              help: "Retransmission timeout derived from SRTT. T1 fires when an ACK takes longer than this."),
    ]
}

// MARK: - AIMD window sawtooth

struct WindowSawtoothView: View {
    let samples: [LinkSessionViz.WindowSample]

    var body: some View {
        Chart {
            ForEach(samples) { s in
                LineMark(x: .value("Time", s.date), y: .value("Outstanding", s.outstanding))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Time", s.date), y: .value("Window", s.windowSize))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .interpolationMethod(.stepEnd)
            }
            ForEach(samples.filter { $0.lossEvent != nil }) { s in
                PointMark(x: .value("Time", s.date), y: .value("Outstanding", s.outstanding))
                    .foregroundStyle(s.lossEvent == "t1" ? .red : .orange)
                    .symbolSize(30)
            }
        }
        .chartYScale(domain: 0...8)
        .chartLegend(.hidden)
        .sessionTimeAxis(start: samples.first?.date, end: samples.last?.date)
    }
}

extension WindowSawtoothView {
    static let legend: [ChartLegend.Item] = [
        .init(swatch: .line(.blue), label: "In flight",
              help: "Frames we have sent and not yet had acknowledged."),
        .init(swatch: .dashedLine(.secondary), label: "Window K",
              help: "The configured window size — the ceiling on frames in flight."),
        .init(swatch: .dot(.orange), label: "REJ",
              help: "A reject we sent: a gap appeared in the peer's stream."),
        .init(swatch: .dot(.red), label: "T1",
              help: "Our own retransmission timeout — no ack arrived in time."),
    ]
}

// MARK: - Throughput (goodput vs raw)

struct ThroughputChartView: View {
    let buckets: [LinkSessionViz.ThroughputBucket]

    private struct RatePoint: Identifiable {
        let date: Date
        let rawRate: Double
        let goodRate: Double
        var id: Date { date }
    }

    /// Per-second buckets read as a picket fence at packet speeds: one
    /// 128-byte block every few seconds draws isolated needles with zero
    /// between them. Average over span-adaptive windows (~70 across the
    /// chart, snapped to human intervals) so the plot shows the sustained
    /// rate, Activity-Monitor style.
    private var ratePoints: [RatePoint] {
        guard let first = buckets.first, let last = buckets.last else { return [] }
        let span = max(1, last.date.timeIntervalSince(first.date))
        let target = span / 70
        let width = [1.0, 2, 5, 10, 15, 30, 60].first { $0 >= target } ?? 120
        let start = first.date.timeIntervalSinceReferenceDate
        var raw = [Int: Int]()
        var good = [Int: Int]()
        for b in buckets {
            let slot = Int((b.date.timeIntervalSinceReferenceDate - start) / width)
            raw[slot, default: 0] += b.rawBytes
            good[slot, default: 0] += b.deliveredBytes
        }
        let slots = Int(span / width)
        return (0...slots).map { slot in
            RatePoint(
                date: Date(timeIntervalSinceReferenceDate: start + (Double(slot) + 0.5) * width),
                rawRate: Double(raw[slot] ?? 0) / width,
                goodRate: Double(good[slot] ?? 0) / width)
        }
    }

    var body: some View {
        Chart {
            ForEach(ratePoints) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Raw", p.rawRate), series: .value("Series", "raw"))
                    .foregroundStyle(.orange.opacity(0.25))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Time", p.date), y: .value("Goodput", p.goodRate), series: .value("Series", "goodput"))
                    .foregroundStyle(.green.opacity(0.45))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Goodput", p.goodRate), series: .value("Series", "goodline"))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYAxisLabel("B/s")
        .chartLegend(.hidden)
        .sessionTimeAxis(start: ratePoints.first?.date, end: ratePoints.last?.date)
    }
}

extension ThroughputChartView {
    static let legend: [ChartLegend.Item] = [
        .init(swatch: .fill(.green.opacity(0.45)), label: "Goodput",
              help: "Bytes delivered in order — the part of the channel that did useful work."),
        .init(swatch: .fill(.orange.opacity(0.25)), label: "Retransmits",
              help: "Channel bytes burned on repeated copies. The gap above the green line is the overhead."),
    ]
}

// MARK: - Block cadence strip

/// Each delivered payload chunk as a cell, colored by how long it took to
/// arrive relative to the running median — a BitTorrent-style strip that
/// makes stalls and retransmit clusters visible at a glance.
struct BlockCadenceStrip: View {
    let deliveries: [LinkSessionViz.Delivery]
    var expectedTotalBytes: Int? = nil
    var receivedBytes: Int = 0

    var body: some View {
        Canvas { context, size in
            guard !deliveries.isEmpty else { return }

            let avg = averageBlockSize ?? 128
            // Bytes carried over from an interrupted session (B2F resume):
            // progress counts them, but they never pass through `deliveries`.
            // Render them as their own leading cells so the strip agrees
            // with the progress bar instead of starting at zero.
            let prefixBytes = max(0, receivedBytes - deliveries.reduce(0) { $0 + $1.bytes })
            let prefixCells = avg > 0 ? Int((Double(prefixBytes) / avg).rounded()) : 0

            // Expected cell count: from the transfer size when known, else
            // just what we have. 128-byte blocks are the norm on packet.
            let cellCount: Int = {
                if let total = expectedTotalBytes, total > 0, avg > 0 {
                    return max(prefixCells + deliveries.count, Int(ceil(Double(total) / avg)))
                }
                return prefixCells + deliveries.count
            }()

            let gaps = interarrivalGaps
            let median = medianGap(gaps)
            let columns = max(1, Int(size.width / 7))
            let rows = max(1, Int(ceil(Double(cellCount) / Double(columns))))
            let cellW = size.width / CGFloat(columns)
            let cellH = min(7, size.height / CGFloat(rows))

            for index in 0..<cellCount {
                let col = index % columns
                let row = index / columns
                let rect = CGRect(
                    x: CGFloat(col) * cellW + 0.5,
                    y: CGFloat(row) * cellH + 0.5,
                    width: cellW - 1, height: cellH - 1)
                guard rect.maxY <= size.height else { break }

                let color: Color
                if index < prefixCells {
                    color = .teal.opacity(0.7)                 // resumed from a prior session
                } else if index - prefixCells < deliveries.count {
                    let deliveryIndex = index - prefixCells
                    if deliveryIndex == deliveries.count - 1 {
                        color = .blue                          // newest
                    } else if deliveryIndex > 0, median > 0, gaps[deliveryIndex - 1] > median * 3 {
                        color = .orange                        // slow: stall/retransmit
                    } else {
                        color = .green
                    }
                } else {
                    color = Color.secondary.opacity(0.15)      // not yet received
                }
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
        .help("Each cell is one delivered block of the transfer, filling left-to-right. Teal was carried over from an interrupted session (resume), green arrived on pace, orange took over 3× the median gap (a stall or retransmit cycle), blue is the newest block, gray is still to come.")
    }

    private var averageBlockSize: Double? {
        guard !deliveries.isEmpty else { return nil }
        return Double(deliveries.reduce(0) { $0 + $1.bytes }) / Double(deliveries.count)
    }

    private var interarrivalGaps: [TimeInterval] {
        guard deliveries.count > 1 else { return [] }
        return (1..<deliveries.count).map {
            deliveries[$0].date.timeIntervalSince(deliveries[$0 - 1].date)
        }
    }

    private func medianGap(_ gaps: [TimeInterval]) -> TimeInterval {
        guard !gaps.isEmpty else { return 0 }
        let sorted = gaps.sorted()
        return sorted[sorted.count / 2]
    }
}

// MARK: - Channel airtime lanes

/// One horizontal lane per heard station; each frame is a tick whose width is
/// its estimated airtime at the channel baud rate.
struct ChannelAirtimeLanesView: View {
    @ObservedObject var monitor: ChannelActivityMonitor
    /// How much history the lanes show.
    var window: TimeInterval = 10 * 60
    var maxLanes = 8

    var body: some View {
        let now = Date()
        let lanes = Array(monitor.lanes.prefix(maxLanes))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Channel activity — last \(Int(window / 60)) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%% busy", monitor.utilization(now: now) * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Fraction of the window the channel carried a frame from any station — shared-frequency etiquette at a glance.")
            }
            if lanes.isEmpty {
                Text("No frames heard yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Canvas { context, size in
                    let laneH = size.height / CGFloat(lanes.count)
                    let start = now.addingTimeInterval(-window)
                    for (laneIndex, lane) in lanes.enumerated() {
                        let y = CGFloat(laneIndex) * laneH
                        // Lane baseline
                        context.stroke(
                            Path { $0.move(to: CGPoint(x: 0, y: y + laneH - 1)); $0.addLine(to: CGPoint(x: size.width, y: y + laneH - 1)) },
                            with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                        for sample in monitor.samples where sample.callsign == lane.callsign {
                            let x = CGFloat(sample.date.timeIntervalSince(start) / window) * size.width
                            guard x >= 0 else { continue }
                            let w = max(1.5, CGFloat(sample.airtimeSeconds / window) * size.width)
                            let rect = CGRect(x: x, y: y + 3, width: w, height: laneH - 7)
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: 1),
                                with: .color(sample.isTransmit ? .blue : .green.opacity(0.8)))
                        }
                        context.draw(
                            Text(lane.callsign)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary),
                            at: CGPoint(x: 4, y: y + laneH / 2), anchor: .leading)
                    }
                }
                .frame(minHeight: CGFloat(lanes.count) * 18, maxHeight: CGFloat(lanes.count) * 24)
                .help("One lane per station, busiest first. Each tick is a frame; tick width is its airtime at the channel baud rate. Blue ticks are your own transmissions, green are received. A thick striped pair of lanes is a connected-mode conversation.")
            }
        }
    }
}

// MARK: - Shared chart furniture

/// A legend the session charts draw themselves.
///
/// Charts' built-in legend keys off a foreground-style *scale*, and these
/// plots deliberately don't use one: goodput is a filled area under a solid
/// line, retransmit overhead is a translucent area above it, and RTO is a
/// dashed line. Flattening all that into scale colours would lose the
/// distinctions the panels exist to show, so the swatches are drawn to
/// match the marks exactly.
struct ChartLegend: View {

    enum Swatch: Equatable {
        case fill(Color)
        case line(Color)
        case dashedLine(Color)
        case dot(Color)
    }

    struct Item: Identifiable, Equatable {
        let swatch: Swatch
        let label: String
        /// The sentence a tooltip would have carried. Kept per item so the
        /// explanation sits next to the thing it explains.
        var help: String?
        var id: String { label }
    }

    let items: [Item]

    var body: some View {
        // Wraps rather than truncates: four items at a narrow panel width
        // would otherwise clip the last one, which is the same class of bug
        // as the axis label running off the edge.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { entries }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 12) { entriesSlice(0..<(items.count + 1) / 2) }
                HStack(spacing: 12) { entriesSlice((items.count + 1) / 2..<items.count) }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var entries: some View { entriesSlice(0..<items.count) }

    private func entriesSlice(_ range: Range<Int>) -> some View {
        ForEach(Array(items[range.clamped(to: 0..<items.count)])) { item in
            HStack(spacing: 4) {
                swatchView(item.swatch)
                Text(item.label)
            }
            .help(item.help ?? item.label)
        }
    }

    @ViewBuilder
    private func swatchView(_ swatch: Swatch) -> some View {
        switch swatch {
        case .fill(let color):
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
        case .line(let color):
            Capsule().fill(color).frame(width: 12, height: 2)
        case .dashedLine(let color):
            HStack(spacing: 2) {
                Capsule().fill(color).frame(width: 4, height: 2)
                Capsule().fill(color).frame(width: 4, height: 2)
            }
            .frame(width: 12)
        case .dot(let color):
            Circle().fill(color).frame(width: 6, height: 6)
        }
    }
}

extension View {
    /// The shared time axis: four ticks, labels sized to the session's own
    /// span, and room at the trailing edge so the last one is not clipped.
    func sessionTimeAxis(start: Date?, end: Date?) -> some View {
        let axis = ChartTimeAxis(
            span: (end?.timeIntervalSince(start ?? Date())) ?? 0)
        let origin = start ?? Date()
        return self
            .chartXAxis {
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: axis.desiredTickCount)) { value in
                    AxisGridLine()
                    AxisTick()
                    if let date = value.as(Date.self) {
                        AxisValueLabel(axis.label(for: date, start: origin), centered: false)
                    }
                }
            }
            // The label at the right-hand tick is drawn from the plot edge
            // outwards, so without this the last one runs under the panel
            // border and loses its tail — "4:..." in the report.
            .padding(.trailing, 14)
    }
}
