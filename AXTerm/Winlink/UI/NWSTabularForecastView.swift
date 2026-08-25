import SwiftUI

/// Renders a parsed NWS tabular state forecast as a real table: one
/// column per forecast day, one row per city, grouped by the product's
/// own regions.
///
/// The raw product stays one disclosure away and is never discarded. It
/// is what actually crossed the air, it is what another operator will
/// quote back, and any disagreement between it and this table means the
/// table is wrong.
struct NWSTabularForecastView: View {

    let forecast: NWSTabularForecast
    /// The product exactly as received, for the raw disclosure.
    let rawText: String
    /// The station's own town, used to pick which city to open on.
    var preferredLocality: String?

    @State private var showsRaw = false
    @State private var showsGrid = false
    @State private var selectedPlaceName: String?

    private let columnWidth: CGFloat = 84
    private let placeColumnWidth: CGFloat = 150

    /// The city on screen: the operator's choice, else their own town, else
    /// the product's first.
    private var selectedPlace: NWSTabularForecast.Place? {
        if let selectedPlaceName,
           let match = forecast.allPlaces.first(where: { $0.name == selectedPlaceName }) {
            return match
        }
        return forecast.defaultPlace(preferring: preferredLocality)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            placePicker
            // One city, seven days, read top to bottom.
            //
            // The product is a spreadsheet — two dozen cities across seven
            // days — and rendering it as one forced a horizontal scroll where
            // a row and its column header could never be on screen together.
            // The question an operator actually has is "what is the weather
            // here", so that is what opens.
            if let place = selectedPlace {
                forecastRows(for: place)
            }
            gridDisclosure
            rawDisclosure
        }
    }

    // MARK: - One place, read vertically

    @ViewBuilder
    private func forecastRows(for place: NWSTabularForecast.Place) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(zip(forecast.days.indices, forecast.days)), id: \.1.id) { index, day in
                if index < place.cells.count {
                    dayRow(day: day, cell: place.cells[index])
                    if index < min(forecast.days.count, place.cells.count) - 1 {
                        Divider()
                    }
                }
            }
        }
        .background(Color(platform: .platformCardBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func dayRow(day: NWSTabularForecast.Day,
                        cell: NWSTabularForecast.Cell) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(day.weekday)
                    .font(.subheadline.weight(.semibold))
                Text(day.date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 62, alignment: .leading)

            Image(systemName: cell.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.title3)
                .frame(width: 30)

            Text(cell.weatherName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Chance of precipitation earns its place only when there is one.
            if let pop = cell.peakPop, pop > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "drop.fill").font(.caption2)
                    Text("\(pop)%").font(.caption.monospacedDigit())
                }
                .foregroundStyle(.teal)
            }

            HStack(spacing: 4) {
                if let high = cell.high {
                    Text("\(high)\u{00B0}")
                        .font(.title3.weight(.medium).monospacedDigit())
                }
                if let low = cell.low {
                    Text("\(low)\u{00B0}")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .explain(rowExplanation(day: day, cell: cell), showsIndicator: false)
    }

    private func rowExplanation(day: NWSTabularForecast.Day,
                                cell: NWSTabularForecast.Cell) -> String {
        var parts = ["\(day.weekday) \(day.date): \(cell.weatherName)."]
        if let high = cell.high, let low = cell.low {
            parts.append("High \(high)\u{00B0}F, low \(low)\u{00B0}F.")
        }
        // The product gives day and night separately; the row shows the worse
        // of the two, so say which is which.
        if let popDay = cell.popDay, let popNight = cell.popNight {
            parts.append("Chance of precipitation \(popDay)% by day and \(popNight)% overnight; the row shows the higher of the two.")
        }
        parts.append("Straight from the product — nothing here is interpolated.")
        return parts.joined(separator: " ")
    }

    // MARK: - Place picker

    @ViewBuilder
    private var placePicker: some View {
        let places = forecast.allPlaces
        if places.count > 1 {
            Menu {
                ForEach(forecast.sections) { section in
                    Section(section.title) {
                        ForEach(section.places) { place in
                            Button {
                                selectedPlaceName = place.name
                            } label: {
                                if place.name == selectedPlace?.name {
                                    Label(place.name, systemImage: "checkmark")
                                } else {
                                    Text(place.name)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "mappin.and.ellipse")
                    Text(selectedPlace?.name ?? "Choose a place")
                        .font(.headline)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                    Spacer(minLength: 0)
                    Text("\(places.count) places")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .explain("This product covers \(places.count) places. Only one is shown at a time because a table of all of them cannot be read without scrolling sideways. The full grid is still below.")
        }
    }

    // MARK: - The whole grid, for comparing places

    private var gridDisclosure: some View {
        DisclosureGroup(isExpanded: $showsGrid) {
            ScrollView(.horizontal, showsIndicators: true) {
                table
            }
            .padding(.top, 6)
        } label: {
            Label("All places", systemImage: "tablecells")
                .font(.caption)
        }
        .explain("Every place in the product at once. Useful for comparing towns along a route; it scrolls sideways because the product genuinely is that wide.")
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "table")
                    .foregroundStyle(.tint)
                Text(forecast.title)
                    .font(.subheadline.weight(.semibold))
                Text(forecast.productId)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("AWIPS product identifier. \(forecast.productId.prefix(3)) is the tabular state forecast; the last two letters are the state.")
            }
            if !forecast.office.isEmpty || !forecast.issued.isEmpty {
                Text([forecast.office, forecast.issued].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("AXTerm parsed this fixed-width product into a table. Every value below is the product's own; nothing is interpolated. Open \u{201C}Raw product text\u{201D} to see exactly what arrived.")
    }

    // MARK: - Table

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            GridRow {
                Text("")
                    .frame(width: placeColumnWidth, alignment: .leading)
                ForEach(forecast.days) { day in
                    VStack(spacing: 0) {
                        Text(day.weekday).font(.caption.weight(.semibold))
                        Text(day.date).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: columnWidth)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)

            ForEach(forecast.sections) { section in
                GridRow {
                    Text(section.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .gridCellColumns(forecast.days.count + 1)
                }
                ForEach(section.places) { place in
                    GridRow {
                        Text(place.name.capitalized)
                            .font(.callout)
                            .lineLimit(1)
                            .frame(width: placeColumnWidth, alignment: .leading)
                            .help(place.name)
                        ForEach(Array(place.cells.enumerated()), id: \.offset) { index, cell in
                            cellView(cell, day: forecast.days[safe: index], place: place.name)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func cellView(_ cell: NWSTabularForecast.Cell,
                          day: NWSTabularForecast.Day?,
                          place: String) -> some View {
        VStack(spacing: 1) {
            Image(systemName: cell.symbolName)
                .font(.body)
                .symbolRenderingMode(.multicolor)
                .frame(height: 18)
            Text(cell.weatherName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 3) {
                Text(temperature(cell.high))
                    .font(.callout.weight(.semibold).monospacedDigit())
                Text(temperature(cell.low))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(popText(cell))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(popTint(cell))
        }
        .frame(width: columnWidth)
        .padding(.vertical, 3)
        .help(tooltip(cell, day: day, place: place))
    }

    // MARK: - Values

    /// Missing data reads as an absence, never as a temperature.
    private func temperature(_ value: Int?) -> String {
        value.map { "\($0)\u{00B0}" } ?? "\u{2014}"
    }

    private func popText(_ cell: NWSTabularForecast.Cell) -> String {
        guard let night = cell.popNight, let day = cell.popDay else { return "\u{2014}" }
        return "\(night)/\(day)%"
    }

    /// Only a genuinely wet forecast earns colour; 20% everywhere would
    /// make the table read as alarming when it is ordinary.
    private func popTint(_ cell: NWSTabularForecast.Cell) -> Color {
        guard let peak = cell.peakPop else { return .secondary }
        if peak >= 60 { return .blue }
        if peak >= 30 { return .teal }
        return .secondary
    }

    /// Says what the value is *and* where it came from — the product,
    /// the office, and the issuance time, so a stale forecast is
    /// recognisable as stale.
    private func tooltip(_ cell: NWSTabularForecast.Cell,
                         day: NWSTabularForecast.Day?,
                         place: String) -> String {
        var lines: [String] = []
        if let day {
            lines.append("\(place.capitalized) \u{2014} \(day.weekday) \(day.date)")
        } else {
            lines.append(place.capitalized)
        }
        lines.append("\(cell.weatherName) (product code \(cell.weatherCode))")

        let high = cell.high.map { "high \($0)\u{00B0}F" }
        let low = cell.low.map { "early-morning low \($0)\u{00B0}F" }
        let temps = [high, low].compactMap { $0 }
        lines.append(temps.isEmpty ? "Temperatures not reported (MM)" : temps.joined(separator: ", ").capitalizedFirst)

        if let night = cell.popNight, let dayPop = cell.popDay {
            lines.append("Precipitation \(night)% overnight (6PM\u{2013}6AM), \(dayPop)% daytime (6AM\u{2013}6PM)")
        }

        var provenance = forecast.productId
        if !forecast.office.isEmpty { provenance += " \u{00B7} " + forecast.office }
        if !forecast.issued.isEmpty { provenance += " \u{00B7} issued " + forecast.issued }
        lines.append("")
        lines.append(provenance)
        return lines.joined(separator: "\n")
    }

    // MARK: - Raw

    private var rawDisclosure: some View {
        DisclosureGroup(isExpanded: $showsRaw) {
            Text(rawText)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text("Raw product text")
                .font(.caption)
        }
        .help("The product exactly as it arrived over the air. The table above is derived from it \u{2014} if the two ever disagree, this is the one that is right.")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
