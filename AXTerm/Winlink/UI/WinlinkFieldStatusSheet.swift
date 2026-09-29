import SwiftUI

/// One screen to check before leaving: is the station actually ready,
/// when does this gateway answer, and how much daylight is left.
///
/// Three things that live in three different places the rest of the
/// time, gathered because the moment they matter is the moment nobody
/// wants to go looking for them.
struct WinlinkFieldStatusSheet: View {

    let readiness: WinlinkReadiness
    let gatewayHours: WinlinkGatewayHours
    /// Nil when no position is known — sun and moon cannot be computed
    /// without one, and guessing a location would be worse than saying so.
    let location: StationLocation?
    var now: Date = Date()

    @Environment(\.dismiss) private var dismiss

    private var solar: SolarEvents? {
        location.map {
            SolarEvents.compute(latitude: $0.latitude, longitude: $0.longitude, date: now)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    readinessSection
                    gatewaySection
                    daylightSection
                }
                .padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 620)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: readiness.overall.symbolName)
                .foregroundStyle(tint(readiness.overall))
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.headline)
                Text(subhead).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var headline: String {
        switch readiness.overall {
        case .ready: "Station ready"
        case .warning: "Ready, with gaps"
        case .blocked: "Not ready"
        }
    }

    private var subhead: String {
        let blockers = readiness.blockers.count
        let warnings = readiness.warnings.count
        if blockers > 0 {
            return "\(blockers) thing\(blockers == 1 ? "" : "s") must be fixed before anything can be sent"
        }
        if warnings > 0 {
            return "\(warnings) thing\(warnings == 1 ? "" : "s") worth fixing while it is cheap"
        }
        return "Every check passed"
    }

    private func tint(_ status: WinlinkReadiness.Status) -> Color {
        switch status {
        case .ready: .green
        case .warning: .orange
        case .blocked: .red
        }
    }

    // MARK: - Sections

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Pre-flight", systemImage: "checklist")
            ForEach(readiness.checks) { check in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: check.status.symbolName)
                        .foregroundStyle(tint(check.status))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(check.title).font(.callout.weight(.medium))
                            Text(check.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let remedy = check.remedy {
                            Text(remedy)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var gatewaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(gatewayHours.callsign.isEmpty
                         ? "When gateways answer"
                         : "When \(gatewayHours.callsign) answers",
                         systemImage: "clock.arrow.circlepath")
            Text(gatewayHours.headline)
                .font(.callout)
                .foregroundStyle(gatewayHours.isTooThin ? .secondary : .primary)
            hourStrip
                .help("One bar per hour of the day, from this station's own session log. Height is how often the gateway answered; a hollow bar means that hour was tried and never answered; nothing means it was never tried. Bucketed by local time, because that is what you plan against.")
        }
    }

    /// A day-long strip is more readable than 24 rows, and the shape is
    /// the point — you are looking for a window, not a number.
    private var hourStrip: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(gatewayHours.hours) { hour in
                VStack(spacing: 2) {
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(height: 34)
                        if let rate = hour.answerRate {
                            Rectangle()
                                .fill(rate > 0 ? Color.accentColor : Color.red.opacity(0.35))
                                .frame(height: max(3, 34 * rate))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    if hour.hour % 6 == 0 {
                        Text("\(hour.hour)")
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(" ").font(.system(size: 8))
                    }
                }
                .help(hourTooltip(hour))
            }
        }
    }

    private func hourTooltip(_ hour: WinlinkGatewayHours.Hour) -> String {
        guard hour.attempts > 0 else {
            return "\(hour.label) — never attempted."
        }
        let percent = Int(((hour.answerRate ?? 0) * 100).rounded())
        return "\(hour.label) — answered \(hour.answered) of \(hour.attempts) attempts (\(percent)%)."
    }

    // A `guard`/`return` inside the closure stopped it being a ViewBuilder,
    // which made the first line an ordinary discarded statement: the
    // "Daylight & moon" heading was built and thrown away, so the section
    // rendered without one. `if`/`else` keeps the builder, and the heading.
    private var daylightSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Daylight & moon", systemImage: "sun.horizon")
            if let solar, let location {
                solarBody(solar, location: location)
            } else {
                Text("No position known, so sun and moon cannot be computed. Set a grid square in Settings → Winlink, or wait for a GPS fix.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func solarBody(_ solar: SolarEvents, location: StationLocation) -> some View {
        let moon = MoonPhase.at(now)
        VStack(alignment: .leading, spacing: 6) {
            if solar.isPolarDay {
                Text("The sun does not set here today.").font(.callout)
            } else if solar.isPolarNight {
                Text("The sun does not rise here today.").font(.callout)
            } else if let remaining = solar.daylightRemaining(from: now) {
                // The number that actually matters on a summit.
                Text("\(formatted(remaining)) of daylight left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(remaining < 3600 ? .orange : .primary)
                    .help("Time from now until sunset at \(location.gridSquare). Civil twilight adds roughly another half hour of usable light.")
            } else {
                Text("The sun is already down").font(.callout).foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                timeRow("Civil dawn", solar.civilDawn)
                timeRow("Sunrise", solar.sunrise)
                timeRow("Solar noon", solar.solarNoon)
                timeRow("Sunset", solar.sunset)
                timeRow("Civil dusk", solar.civilDusk)
            }
            .font(.callout)

            HStack(spacing: 6) {
                Image(systemName: moon.symbolName)
                Text("\(moon.name) \u{00B7} \(Int((moon.illuminatedFraction * 100).rounded()))% lit")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .help("Mean-synodic approximation — good enough for whether there will be light to pack up by, not for an almanac.")

            if !solar.grayLineWindows().isEmpty {
                Text("Gray line: " + solar.grayLineWindows()
                        .map { "\($0.label) \(clock($0.start))–\(clock($0.end))" }
                        .joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("HF paths open along the terminator, so a marginal band is most likely workable in these windows.")
            }

            Text("Computed locally from \(location.gridSquare) — no network, gateway, or radio involved.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func timeRow(_ label: String, _ date: Date?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(date.map(clock) ?? "—").monospacedDigit()
        }
    }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
