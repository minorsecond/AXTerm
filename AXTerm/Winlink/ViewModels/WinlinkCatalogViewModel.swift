import Foundation
import Combine

/// Catalog browser: cache-first list of Winlink data products, with
/// multi-select and request-message generation.
@MainActor
final class WinlinkCatalogViewModel: ObservableObject {

    struct CategoryGroup: Identifiable, Hashable {
        var id: String { category }
        var category: String
        var items: [WinlinkCatalogItemRecord]
    }

    @Published private(set) var groups: [CategoryGroup] = []

    /// Search text. Setting it re-derives `families` and `matchingItems`
    /// once; the browser reads the cached results rather than regrouping
    /// ~1450 products on every SwiftUI redraw.
    @Published var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            rebuildFamilies()
        }
    }

    /// The catalog as a browsable hierarchy, narrowed by `searchQuery`.
    @Published private(set) var families: [WinlinkCatalogTaxonomy.Family] = []
    /// Flat view of the same thing — every product matching the search.
    @Published private(set) var matchingItems: [WinlinkCatalogItemRecord] = []

    /// InquiryIds the operator starred. Kept whole even when the current
    /// index no longer carries one — a product disappearing from the
    /// catalog is worth noticing, not worth silently forgetting.
    @Published private(set) var favorites = Set<String>()

    @Published var selection = Set<String>()
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorText: String?
    @Published private(set) var fetchedAt: Date?

    private let store: WinlinkStore
    /// Built per refresh so a key entered in Settings applies immediately.
    private let makeClient: () -> CMSClienting

    init(store: WinlinkStore, makeClient: @escaping () -> CMSClienting) {
        self.store = store
        self.makeClient = makeClient
        loadCache()
    }

    func loadCache() {
        do {
            var items = try store.catalogItems().filter(\.enabled)
            if items.isEmpty, let ingested = try ingestLatestListReply() {
                items = ingested.filter(\.enabled)
            }
            let grouped = Dictionary(grouping: items, by: \.category)
            groups = grouped
                .map { CategoryGroup(category: $0.key, items: $0.value.sorted { $0.subject < $1.subject }) }
                .sorted { $0.category < $1.category }
            fetchedAt = items.map(\.fetchedAt).max()
            favorites = (try? store.catalogFavorites()) ?? favorites
            rebuildFamilies()
        } catch {
            errorText = String(describing: error)
        }
    }

    /// Re-derives the browsable hierarchy from the cache and the current
    /// search. Called when either changes — never from a view body.
    private func rebuildFamilies() {
        let items = groups.flatMap(\.items)
        matchingItems = items.filter { WinlinkCatalogTaxonomy.matches($0, query: searchQuery) }
        families = WinlinkCatalogTaxonomy.families(from: matchingItems)
    }

    /// Fills an empty cache from mail already on hand: the newest
    /// SERVICE message that parses as the inquiry server's LIST reply.
    /// (New replies also ingest at receive time; this covers replies
    /// that arrived before ingestion existed, or after a cache clear.)
    private func ingestLatestListReply() throws -> [WinlinkCatalogItemRecord]? {
        for stored in try store.inboundMessages(fromAddr: "SERVICE", limit: 8) {
            guard let items = WinlinkCatalogListReply.parse(stored.message) else { continue }
            try store.replaceCatalogCache(items)
            return items
        }
        return nil
    }

    /// The starred products present in the current index, honouring the
    /// active search. Favourites the index no longer carries are absent
    /// here but still remembered in `favorites`.
    var favoriteItems: [WinlinkCatalogItemRecord] {
        matchingItems
            .filter { favorites.contains($0.inquiryId) }
            .sorted { WinlinkCatalogTaxonomy.displayTitle($0) < WinlinkCatalogTaxonomy.displayTitle($1) }
    }

    /// The products queued into the next request.
    ///
    /// Unlike `favoriteItems` this deliberately ignores `searchQuery`.
    /// The selection is a basket the operator reviews before queueing,
    /// and narrowing it as they type would look exactly like selections
    /// being lost.
    var selectedItems: [WinlinkCatalogItemRecord] {
        groups.flatMap(\.items)
            .filter { selection.contains($0.inquiryId) }
            .sorted { WinlinkCatalogTaxonomy.displayTitle($0) < WinlinkCatalogTaxonomy.displayTitle($1) }
    }

    func toggleFavorite(_ inquiryId: String) {
        let isFavorite = !favorites.contains(inquiryId)
        do {
            try store.setCatalogFavorite(inquiryId: inquiryId, isFavorite: isFavorite)
            if isFavorite {
                favorites.insert(inquiryId)
            } else {
                favorites.remove(inquiryId)
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorText = nil
        defer { isRefreshing = false }

        do {
            let items = try await makeClient().inquiriesCatalog()
            try store.replaceCatalogCache(items)
            loadCache()
        } catch {
            errorText = RMSStationsViewModel.describe(error)
        }
    }

    /// Total estimated response size for the current selection.
    var selectedSizeEstimate: Int {
        groups.flatMap(\.items)
            .filter { selection.contains($0.inquiryId) }
            .reduce(0) { $0 + $1.sizeEstimate }
    }

    /// Builds the catalog request: a message to `INQUIRY` with subject
    /// `REQUEST` listing one InquiryId per line — the format Winlink
    /// Express generates. The response arrives as ordinary mail.
    func buildRequestMessage(myCallsign: String) -> WinlinkB2Message? {
        let ids = groups.flatMap(\.items)
            .map(\.inquiryId)
            .filter { selection.contains($0) }
        guard !ids.isEmpty, !myCallsign.isEmpty else { return nil }

        let body = ids.joined(separator: "\r\n") + "\r\n"
        return WinlinkB2Message(
            mid: WinlinkB2Message.generateMID(callsign: myCallsign),
            date: Date(),
            type: .inquiry,
            from: myCallsign,
            to: ["INQUIRY"],
            cc: [],
            subject: "REQUEST",
            mbo: myCallsign,
            body: Data(body.utf8),
            attachments: [])
    }

    /// Queues a request for the catalog *index* over the air: a `LIST`
    /// inquiry whose reply enumerates the available products. This is the
    /// key-free path — the CMS catalog web service needs a personal
    /// access key, but the radio path works for everyone.
    @discardableResult
    func queueCatalogListRequest(myCallsign: String) -> String? {
        guard !myCallsign.isEmpty else {
            errorText = "Set your callsign in Settings before requesting."
            return nil
        }
        let message = WinlinkB2Message(
            mid: WinlinkB2Message.generateMID(callsign: myCallsign),
            date: Date(),
            type: .inquiry,
            from: myCallsign,
            to: ["INQUIRY"],
            cc: [],
            subject: "REQUEST",
            mbo: myCallsign,
            body: Data("LIST\r\n".utf8),
            attachments: [])
        do {
            try store.saveDraft(message)
            try store.queueDraft(mid: message.mid)
            return message.mid
        } catch {
            errorText = String(describing: error)
            return nil
        }
    }

    /// Queues a SailDocs request (internet-over-Winlink). Returns the MID.
    @discardableResult
    func queueSailDocsRequest(_ requests: [SailDocsRequestBuilder.Request], myCallsign: String) -> String? {
        guard let message = SailDocsRequestBuilder.buildMessage(requests: requests, myCallsign: myCallsign) else {
            errorText = requests.isEmpty ? "Enter a request first." : "Set your callsign in Settings first."
            return nil
        }
        do {
            try store.saveDraft(message)
            try store.queueDraft(mid: message.mid)
            return message.mid
        } catch {
            errorText = String(describing: error)
            return nil
        }
    }

    /// Queues a loopback test message to the Winlink TEST bot, which
    /// echoes it back — the standard end-to-end sanity check.
    @discardableResult
    func queueTestMessage(myCallsign: String) -> String? {
        guard !myCallsign.isEmpty else {
            errorText = "Set your callsign in Settings first."
            return nil
        }
        let message = WinlinkB2Message(
            mid: WinlinkB2Message.generateMID(callsign: myCallsign),
            date: Date(),
            type: .privateMessage,
            from: myCallsign,
            to: ["TEST"],
            cc: [],
            subject: "Test message from \(myCallsign)",
            mbo: myCallsign,
            body: Data("This is a Winlink loopback test from AXTerm. The TEST bot echoes this message back.\r\n".utf8),
            attachments: [])
        do {
            try store.saveDraft(message)
            try store.queueDraft(mid: message.mid)
            return message.mid
        } catch {
            errorText = String(describing: error)
            return nil
        }
    }

    /// Queues the request into the Outbox. Returns the MID on success.
    @discardableResult
    func queueRequest(myCallsign: String) -> String? {
        guard let message = buildRequestMessage(myCallsign: myCallsign) else {
            errorText = selection.isEmpty
                ? "Select at least one catalog item."
                : "Set your callsign in Settings before requesting."
            return nil
        }
        do {
            try store.saveDraft(message)
            try store.queueDraft(mid: message.mid)
            selection.removeAll()
            return message.mid
        } catch {
            errorText = String(describing: error)
            return nil
        }
    }
}
