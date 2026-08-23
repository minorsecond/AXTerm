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
    @Published var selection = Set<String>()
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorText: String?
    @Published private(set) var fetchedAt: Date?

    private let store: WinlinkStore
    private let client: CMSClienting

    init(store: WinlinkStore, client: CMSClienting) {
        self.store = store
        self.client = client
        loadCache()
    }

    func loadCache() {
        do {
            let items = try store.catalogItems().filter(\.enabled)
            let grouped = Dictionary(grouping: items, by: \.category)
            groups = grouped
                .map { CategoryGroup(category: $0.key, items: $0.value.sorted { $0.subject < $1.subject }) }
                .sorted { $0.category < $1.category }
            fetchedAt = items.map(\.fetchedAt).max()
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
            let items = try await client.inquiriesCatalog()
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
