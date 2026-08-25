import SwiftUI

/// Winlink catalog browser: pick data products (weather, bulletins…),
/// queue a request message, receive the products as mail later.
///
/// The catalog is ~1450 products across ~126 category codes, so the
/// browser is two-pane: a sidebar of families → categories (see
/// `WinlinkCatalogTaxonomy`) and a filtered product list. Search runs
/// across the whole catalog, not just the selected category, and the
/// footer keeps the running airtime cost of the selection in view —
/// requesting 200 kB of radar over a 1200-baud path is an hour of
/// airtime, and that should be visible before the request is queued.
struct WinlinkCatalogSheet: View {

    enum Source: String, CaseIterable {
        case catalog = "Winlink Catalog"
        case sailDocs = "Internet (SailDocs)"
    }

    /// What the product list is showing.
    private enum Scope: Hashable {
        case all
        case selected
        case favorites
        case outageKit
        case category(String)
    }

    @ObservedObject var viewModel: WinlinkCatalogViewModel
    let myCallsign: String
    /// The operator's USPS state code, for the outage kit's local
    /// forecasts. Empty stages no local weather rather than someone
    /// else's.
    var operatorState: String = ""
    /// Airtime cost model for the gateway this station will actually
    /// work — measured from its own session history where possible.
    var airtime: WinlinkAirtimeEstimate = .assumed
    var locationService: StationLocationService?
    var onQueued: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var queuedConfirmation = false
    @State private var source: Source = .catalog
    @State private var sailDocsURL = ""
    @State private var sailDocsCustom = ""
    @State private var isFetchingSpot = false
    @State private var scope: Scope = .all
    /// Which sidebar families are open. Empty by default: six family
    /// headers fit on screen at once, 126 category rows do not, and the
    /// operator should choose what to unfold rather than scroll past it.
    @State private var expandedFamilies: Set<WinlinkCatalogTaxonomy.Kind> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if source == .sailDocs {
                sailDocsPane
            } else if viewModel.groups.isEmpty {
                emptyCatalogState
            } else {
                catalogBrowser
            }

            Divider()
            footer
        }
        .frame(minWidth: 880, minHeight: 560)
        // The cache can change while the sheet is closed — an exchange
        // ingests the radio-path LIST reply — so reload on every open.
        .onAppear { viewModel.loadCache() }
        // A search that excludes the category you were reading would
        // otherwise leave the pane blank while its results sit unseen in
        // other categories; fall back to showing the matches.
        .onChange(of: viewModel.searchQuery) { _, query in
            if case .category(let raw) = scope,
               !families.contains(where: { family in
                   family.categories.contains { $0.rawCategory == raw }
               }) {
                scope = .all
            }
            // Collapsed sections would hide the very matches the search
            // just found, so a search unfolds whatever still has any —
            // and clearing it returns to the tidy default.
            expandedFamilies = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? []
                : Set(families.map(\.kind))
        }
        .alert("Request queued", isPresented: $queuedConfirmation) {
            Button("OK") { dismiss() }
        } message: {
            Text("The catalog request is in your Outbox. Run Connect & Exchange to send it; the response arrives as ordinary mail on a later exchange.")
        }
    }

    // MARK: - Derived catalog

    /// Both the sidebar counts and the product list read the view
    /// model's cached derivation, so a search narrows the whole browser
    /// and nothing regroups the catalog inside `body`.
    private var families: [WinlinkCatalogTaxonomy.Family] { viewModel.families }

    /// Products worth having on disk before the path you would use to
    /// request them is gone. Built from the whole catalog rather than
    /// the search results — the kit is a fixed rule, not a view of what
    /// you happen to be looking at.
    private var outageKit: [WinlinkOutageKit.Selection] {
        WinlinkOutageKit.build(
            items: viewModel.groups.flatMap(\.items), state: operatorState)
    }

    /// The products the right pane lists, already search-filtered.
    private var scopedItems: [WinlinkCatalogItemRecord] {
        switch scope {
        case .all:
            return families.flatMap { $0.categories.flatMap(\.items) }
        case .selected:
            return viewModel.selectedItems
        case .favorites:
            return viewModel.favoriteItems
        case .outageKit:
            return outageKit.map(\.item)
        case .category(let raw):
            return families
                .flatMap(\.categories)
                .first { $0.rawCategory == raw }?
                .items ?? []
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: "All Products"
        case .selected: "Selected Products"
        case .favorites: "Favorites"
        case .outageKit: "Outage Kit"
        case .category(let raw): WinlinkCatalogTaxonomy.categoryTitle(raw)
        }
    }

    private var scopedBytes: Int {
        scopedItems.reduce(0) { $0 + $1.sizeEstimate }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .labelsHidden()
            .help(source == .catalog ? WinlinkCopy.catalogTooltip
                  : "SailDocs is a free email robot reachable through the Winlink internet gateway — it mails back web pages, forecasts, and weather data. The unofficial way to pull internet data over packet radio.")

            if source == .catalog, !viewModel.groups.isEmpty {
                searchField
            }

            Spacer(minLength: 8)

            if let fetchedAt = viewModel.fetchedAt {
                Text("Updated \(fetchedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("When this catalog index was cached — from the CMS web service, or from an inquiry-server LIST reply received by radio.")
            }
            Button {
                Task { await viewModel.refresh() }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(viewModel.isRefreshing)
            .help(WinlinkCopy.catalogRefreshTooltip)
        }
        .padding(12)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 260)
        .help("Searches every product's subject, its ID, and its category — including the friendly category name, so \"alaska\" finds WX_AK_COAST even though neither the subject nor the code says Alaska.")
    }

    // MARK: - Browser

    private var catalogBrowser: some View {
        VStack(spacing: 0) {
            if let error = viewModel.errorText {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            // Two panes side by side where there is width to drag, and a
            // navigable split where there is not — the catalog is 1,466
            // products, so browsing it one column at a time on a phone is
            // the only shape that works.
            #if os(macOS)
            HSplitView {
                sidebar
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 340)
                productPane
                    .frame(minWidth: 400)
            }
            #else
            NavigationSplitView {
                sidebar
            } detail: {
                productPane
            }
            #endif
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                sidebarRow(.all, title: "All Products",
                           systemImage: "square.stack.3d.up",
                           count: count(for: .all))
                sidebarRow(.selected, title: "Selected",
                           systemImage: "checkmark.circle",
                           count: count(for: .selected))
                    .help("The products queued into the next request.")
                sidebarRow(.favorites, title: "Favorites",
                           systemImage: "star",
                           count: count(for: .favorites))
                    .help("Products you starred. Favorites are kept in their own table, so a catalog refresh never clears them — and a star survives even if a later index drops the product.")
                sidebarRow(.outageKit, title: "Outage Kit",
                           systemImage: "shippingbox",
                           count: count(for: .outageKit))
                    .help(outageKitTooltip)
            }
            ForEach(families) { family in
                Section(isExpanded: expansion(for: family.kind)) {
                    ForEach(family.categories) { category in
                        sidebarRow(.category(category.rawCategory),
                                   title: category.title,
                                   systemImage: nil,
                                   count: category.items.count)
                            .help("\(category.rawCategory) — \(category.items.count) product\(category.items.count == 1 ? "" : "s"), \(airtime.tooltip(bytes: category.totalBytes))")
                    }
                } header: {
                    Label(family.title, systemImage: family.systemImage)
                        .help("\(family.itemCount) products across \(family.categories.count) categories. Sections come from the gateway's own category codes — see Docs/Winlink.md.")
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// `List` selection drives the scope, but "no selection" is not a
    /// valid state here — clicking away keeps the current pane.
    private var sidebarSelection: Binding<Scope?> {
        Binding(get: { scope }, set: { if let new = $0 { scope = new } })
    }

    /// How many products a sidebar row would show if clicked, so no
    /// count contradicts the list that opens. Browsing scopes honour the
    /// search; Selected does not — see `selectedItems`.
    private func count(for target: Scope) -> Int {
        switch target {
        case .all: viewModel.matchingItems.count
        case .selected: viewModel.selection.count
        case .favorites: viewModel.favoriteItems.count
        case .outageKit: outageKit.count
        case .category(let raw): families.flatMap(\.categories)
                .first { $0.rawCategory == raw }?.items.count ?? 0
        }
    }

    /// Says what the kit is and why each thing is in it — the rule is
    /// fixed, so it can be stated rather than guessed at.
    private var outageKitTooltip: String {
        let bytes = WinlinkOutageKit.totalBytes(outageKit)
        var text = """
        Products worth requesting before the path you would use to request \
        them is gone: frequency plans and net schedules (ICS-205s, P2P nets), \
        key system reference, propagation basics
        """
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text += operatorState.isEmpty
            ? ", and — once your state is set in Settings → Winlink — local forecasts."
            : ", and forecasts for \(operatorState.uppercased())."
        if !outageKit.isEmpty {
            text += "\n\n\(outageKit.count) products, "
            text += "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), "
            text += "\u{2248}\(airtime.airtimeText(bytes: bytes)) of airtime."
        }
        text += "\n\nBulk weather — radar, fax — is deliberately excluded: too large, and stale within the hour."
        return text
    }

    private func expansion(for kind: WinlinkCatalogTaxonomy.Kind) -> Binding<Bool> {
        Binding(
            get: { expandedFamilies.contains(kind) },
            set: { isOpen in
                if isOpen {
                    expandedFamilies.insert(kind)
                } else {
                    expandedFamilies.remove(kind)
                }
            })
    }

    private func sidebarRow(_ target: Scope,
                            title: String,
                            systemImage: String?,
                            count: Int) -> some View {
        HStack {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .tag(target)
    }

    private var productPane: some View {
        VStack(spacing: 0) {
            productPaneHeader
            Divider()
            if scopedItems.isEmpty {
                emptyScopeState
            } else {
                List {
                    if case .category = scope {
                        ForEach(scopedItems, id: \.inquiryId) { row(for: $0) }
                    } else {
                        // Outside a single category the products need
                        // their category shown, or two similarly named
                        // forecasts are indistinguishable.
                        ForEach(groupedScopedItems, id: \.0) { raw, items in
                            Section(WinlinkCatalogTaxonomy.categoryTitle(raw)) {
                                ForEach(items, id: \.inquiryId) { row(for: $0) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var groupedScopedItems: [(String, [WinlinkCatalogItemRecord])] {
        Dictionary(grouping: scopedItems, by: \.category)
            .map { ($0.key, $0.value) }
            .sorted { WinlinkCatalogTaxonomy.categoryTitle($0.0) < WinlinkCatalogTaxonomy.categoryTitle($1.0) }
    }

    private var productPaneHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scopeTitle).font(.headline)
                HStack(spacing: 6) {
                    Text("\(scopedItems.count) product\(scopedItems.count == 1 ? "" : "s")")
                    if scopedBytes > 0 {
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: Int64(scopedBytes), countStyle: .file))
                        Text("·")
                        Text("≈\(airtime.airtimeText(bytes: scopedBytes)) airtime")
                    }
                    if case .category(let raw) = scope {
                        Text("·")
                        Text(raw).font(.caption.monospaced())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(scopedBytes > 0
                      ? airtime.tooltip(bytes: scopedBytes)
                      : "Nothing here to size.")
            }
            Spacer()
            if !scopedItems.isEmpty {
                Button(allScopedSelected ? "Deselect All" : "Select All") {
                    let ids = scopedItems.map(\.inquiryId)
                    if allScopedSelected {
                        viewModel.selection.subtract(ids)
                    } else {
                        viewModel.selection.formUnion(ids)
                    }
                }
                .help(allScopedSelected
                      ? "Removes these \(scopedItems.count) products from the request."
                      : "Adds all \(scopedItems.count) products shown — ≈\(airtime.airtimeText(bytes: scopedBytes)) of airtime.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var allScopedSelected: Bool {
        !scopedItems.isEmpty && scopedItems.allSatisfy { viewModel.selection.contains($0.inquiryId) }
    }

    private var emptyScopeState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptyScopeSymbol)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(emptyScopeText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyScopeSymbol: String {
        switch scope {
        case .selected: "checkmark.circle"
        case .favorites: "star"
        case .outageKit: "shippingbox"
        default: viewModel.searchQuery.isEmpty ? "tray" : "magnifyingglass"
        }
    }

    private var emptyScopeText: String {
        if !viewModel.searchQuery.isEmpty {
            return "No products match \u{201C}\(viewModel.searchQuery)\u{201D}"
        }
        switch scope {
        case .selected:
            return "Nothing selected yet"
        case .outageKit:
            return viewModel.groups.isEmpty
                ? "The catalog index has to be cached before a kit can be built"
                : "Nothing in this index matches the outage kit. Set your state in Settings \u{2192} Winlink to include local forecasts."
        case .favorites:
            // Distinguish "you have not starred anything" from "the
            // products you starred are gone from this index".
            guard !viewModel.favorites.isEmpty else {
                return "No favorites yet \u{2014} star a product to keep it here"
            }
            let count = viewModel.favorites.count
            return "Your \(count) starred product\(count == 1 ? " is" : "s are") not in this catalog index. They are still remembered, and reappear if a later index carries them."
        default:
            return "No products here"
        }
    }

    private var emptyCatalogState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("No catalog cached yet")
                .font(.headline)
            Text("The catalog web service needs a personal access key, but every station can request the catalog **over the air**: queue a LIST inquiry, send it with Connect & Exchange, and the index arrives as mail.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let error = viewModel.errorText {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button {
                if viewModel.queueCatalogListRequest(myCallsign: myCallsign) != nil {
                    queuedConfirmation = true
                    onQueued()
                }
            } label: {
                Label("Request Catalog by Radio", systemImage: "antenna.radiowaves.left.and.right")
            }
            .help("Queues a LIST inquiry to INQUIRY in your Outbox — no internet or access key needed.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !viewModel.selection.isEmpty {
                let bytes = viewModel.selectedSizeEstimate
                let sessions = airtime.sessionsRequired(bytes: bytes)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(viewModel.selection.count) selected")
                        Text("·")
                        Text("≈\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                        Text("·")
                        Label("≈\(airtime.airtimeText(bytes: bytes))",
                              systemImage: "clock")
                            .foregroundStyle(airtimeIsHeavy(bytes) ? .orange : .secondary)
                        // Say whether that clock is evidence or a
                        // stand-in; an operator reading a number off a
                        // screen deserves to know which it is.
                        Text("(\(airtime.provenance))")
                            .foregroundStyle(airtime.isMeasured ? .secondary : .tertiary)
                    }
                    if sessions > 1 {
                        // A gateway that hangs up at 17 minutes will cut
                        // a 45-minute request off twice however good the
                        // path is — that is not visible from the clock.
                        Label("Needs about \(sessions) exchanges — \(airtime.gateway ?? "this gateway") has never held a session longer than \(WinlinkAirtimeEstimate.durationText(airtime.sessionCapSeconds ?? 0))",
                              systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(airtime.tooltip(bytes: bytes))

                Button("Clear") { viewModel.selection.removeAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }
            Spacer()
            Button("Close") { dismiss() }
            if source == .catalog {
                Button("Request \(viewModel.selection.count) Item\(viewModel.selection.count == 1 ? "" : "s")") {
                    if viewModel.queueRequest(myCallsign: myCallsign) != nil {
                        queuedConfirmation = true
                        onQueued()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.selection.isEmpty)
                .help("Queues a request message to INQUIRY in your Outbox. Send it with Connect & Exchange; the data arrives as mail at a later exchange.")
            }
        }
        .padding(12)
    }

    /// Ten minutes is where a request stops being a quick add-on to an
    /// exchange and becomes the exchange.
    private func airtimeIsHeavy(_ bytes: Int) -> Bool {
        airtime.estimatedSeconds(bytes: bytes) >= 600
    }

    // MARK: - SailDocs

    private var sailDocsPane: some View {
        Form {
            Section {
                Text("SailDocs (saildocs.com) answers email commands with web pages, forecasts, and weather data — through the Winlink internet gateway, that means over the radio. Requests queue in your Outbox; replies arrive as mail at a later exchange. Keep responses small: 10 kB is roughly two minutes of airtime at 1200 baud.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Fetch a web page as text") {
                HStack {
                    TextField("URL", text: $sailDocsURL, prompt: Text("https://forecast.weather.gov/…"))
                        .textFieldStyle(.roundedBorder)
                    Button("Queue") {
                        queueSailDocs([.webPage(url: sailDocsURL)])
                        sailDocsURL = ""
                    }
                    .disabled(sailDocsURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .help("SailDocs strips the page to plain text before mailing it back — 'send <url>'.")
            }

            if locationService != nil {
                Section("Weather for my position") {
                    Button {
                        isFetchingSpot = true
                        Task { @MainActor in
                            defer { isFetchingSpot = false }
                            guard let location = await locationService?.currentLocation() else { return }
                            queueSailDocs([.spotForecast(
                                latitude: location.latitude, longitude: location.longitude)])
                        }
                    } label: {
                        if isFetchingSpot {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Queue spot forecast for my position", systemImage: "location")
                        }
                    }
                    .disabled(isFetchingSpot)
                    .help("Requests a SailDocs text spot forecast ('send spot:lat,lon') for your current position — GPS when available, otherwise your grid square.")
                }
            }

            Section("Custom command") {
                HStack {
                    TextField("Command", text: $sailDocsCustom, prompt: Text("e.g. send gfs:38N,42N,102W,108W"))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Button("Queue") {
                        queueSailDocs([.custom(sailDocsCustom)])
                        sailDocsCustom = ""
                    }
                    .disabled(sailDocsCustom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .help("Any SailDocs command line (see saildocs.com for the full list). GRIB requests return binary attachments — mind the airtime.")
            }
        }
        .formStyle(.grouped)
    }

    private func queueSailDocs(_ requests: [SailDocsRequestBuilder.Request]) {
        if viewModel.queueSailDocsRequest(requests, myCallsign: myCallsign) != nil {
            queuedConfirmation = true
            onQueued()
        }
    }

    // MARK: - Product row

    private func row(for item: WinlinkCatalogItemRecord) -> some View {
        // The star is a sibling of the checkbox, not part of its label —
        // inside the label a click would also toggle the selection.
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.selection.contains(item.inquiryId) },
                set: { selected in
                    if selected {
                        viewModel.selection.insert(item.inquiryId)
                    } else {
                        viewModel.selection.remove(item.inquiryId)
                    }
                })) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(WinlinkCatalogTaxonomy.displayTitle(item))
                            .lineLimit(2)
                        Text(item.inquiryId)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.sizeEstimate), countStyle: .file))
                        Text("\u{2248}\(airtime.airtimeText(bytes: item.sizeEstimate))")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(airtime.tooltip(bytes: item.sizeEstimate))
                }
            }
            .platformCheckboxToggle()

            favoriteButton(for: item)
        }
    }

    private func favoriteButton(for item: WinlinkCatalogItemRecord) -> some View {
        let isFavorite = viewModel.favorites.contains(item.inquiryId)
        return Button {
            viewModel.toggleFavorite(item.inquiryId)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? .yellow : .secondary)
        }
        .buttonStyle(.plain)
        .help(isFavorite
              ? "Remove from Favorites."
              : "Add to Favorites \u{2014} kept across catalog refreshes, and reachable from the sidebar.")
    }
}
