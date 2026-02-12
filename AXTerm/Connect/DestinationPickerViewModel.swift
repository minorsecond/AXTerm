import Foundation
import Combine

struct DestinationSuggestionRow: Identifiable, Hashable {
    enum Section: String, CaseIterable {
        case favorites
        case recent
        case neighbors

        var title: String {
            switch self {
            case .favorites: return "Favorites"
            case .recent: return "Recent Heard"
            case .neighbors: return "Neighbors"
            }
        }
    }

    let id: String
    let callsign: String
    let secondaryText: String
    let section: Section
    let isFavorite: Bool
    let aliasText: String?

    init(callsign: String, secondaryText: String, section: Section, isFavorite: Bool, aliasText: String? = nil) {
        let normalized = DestinationPickerViewModel.normalizeCandidate(callsign)
        self.id = normalized.isEmpty ? UUID().uuidString : "\(section.rawValue)::\(normalized)"
        self.callsign = normalized.isEmpty ? callsign : normalized
        self.secondaryText = secondaryText
        self.section = section
        self.isFavorite = isFavorite
        self.aliasText = aliasText
    }
}

struct DestinationSuggestionSection: Identifiable, Hashable {
    let id: String
    let title: String
    let rows: [DestinationSuggestionRow]
}

enum DestinationValidationState: Equatable {
    case empty
    case valid(String)
    case invalid(String)

    var inlineError: String? {
        if case let .invalid(reason) = self {
            return reason
        }
        return nil
    }

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

enum DestinationAliasEvidence: Hashable {
    case digipeatReference
    case nodeIdentifier
    case userConfirmed
}

final class DestinationPickerViewModel: ObservableObject {
    @Published var typedText: String = ""
    @Published var validationState: DestinationValidationState = .empty
    @Published var isPopoverPresented = false
    @Published var highlightedSuggestionID: String?
    @Published private(set) var visibleSections: [DestinationSuggestionSection] = []
    @Published private(set) var didYouMeanRow: DestinationSuggestionRow?

    private(set) var selectedStation: String?

    private var recentValues: [String] = []
    private var neighborValues: [String] = []
    private var baseFavorites: Set<String> = []
    private var userFavorites: Set<String> = []
    private var aliasEvidence: [AliasKey: Set<DestinationAliasEvidence>] = [:]

    private let favoritesDefaultsKey = "destinationPicker.userFavorites"
    private let aliasDefaultsKey = "destinationPicker.aliasEvidence"
    private let defaults: UserDefaults

    private struct AliasKey: Hashable {
        let left: String
        let right: String

        init(_ a: String, _ b: String) {
            if a <= b {
                left = a
                right = b
            } else {
                left = b
                right = a
            }
        }
    }

    private struct PersistedAliasLink: Codable {
        let left: String
        let right: String
        let evidence: [DestinationAliasEvidenceCodable]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadPersistedFavorites()
        loadPersistedAliasEvidence()
    }

    func syncExternalDestination(_ value: String, preserveSelection: Bool = true) {
        let normalized = Self.normalizeCandidate(value)
        guard normalized != typedText else { return }
        typedText = normalized
        if !preserveSelection {
            selectedStation = nil
        }
        updateValidationAndSuggestions()
    }

    func updateDataSources(groups: [ConnectSuggestionGroup]) {
        var recents: [String] = []
        var neighbors: [String] = []
        var favorites: [String] = []

        for group in groups {
            switch group.id {
            case "favorites":
                favorites.append(contentsOf: group.values)
            case "recent", "routes":
                recents.append(contentsOf: group.values)
            case "neighbors":
                neighbors.append(contentsOf: group.values)
            default:
                break
            }
        }

        baseFavorites = Set(favorites.map(Self.normalizeCandidate).filter { !$0.isEmpty })
        recentValues = dedupeNormalized(recents)
        neighborValues = dedupeNormalized(neighbors)
        updateValidationAndSuggestions()
    }

    func handleTypedTextChanged(_ raw: String, autoOpenPopover: Bool = true) {
        typedText = Self.sanitizeForTyping(raw)
        selectedStation = nil
        updateValidationAndSuggestions()
        if autoOpenPopover && !isPopoverPresented {
            isPopoverPresented = true
        }
    }

    @discardableResult
    func commitSelection() -> String? {
        if let highlighted = highlightedRow(), let resolved = resolveCommit(for: highlighted.callsign) {
            applySelection(resolved)
            return resolved
        }

        guard case let .valid(value) = validationState else {
            return nil
        }

        applySelection(value)
        return value
    }

    func openSuggestions() {
        isPopoverPresented = true
        if highlightedSuggestionID == nil {
            highlightedSuggestionID = visibleSections.first?.rows.first?.id
        }
    }

    func dismissSuggestions() {
        isPopoverPresented = false
    }

    func moveHighlight(up: Bool) {
        let rows = flattenedRowsIncludingDidYouMean()
        guard !rows.isEmpty else { return }

        guard let current = highlightedSuggestionID,
              let idx = rows.firstIndex(where: { $0.id == current }) else {
            highlightedSuggestionID = rows.first?.id
            return
        }

        let next = up ? max(0, idx - 1) : min(rows.count - 1, idx + 1)
        highlightedSuggestionID = rows[next].id
    }

    func setHighlightedSuggestion(_ id: String?) {
        highlightedSuggestionID = id
    }

    func selectSuggestion(_ row: DestinationSuggestionRow) {
        guard let resolved = resolveCommit(for: row.callsign) else { return }
        applySelection(resolved)
    }

    func toggleFavorite(_ callsign: String) {
        let normalized = Self.normalizeCandidate(callsign)
        guard !normalized.isEmpty else { return }

        if userFavorites.contains(normalized) {
            userFavorites.remove(normalized)
        } else {
            userFavorites.insert(normalized)
        }
        persistFavorites()
        updateValidationAndSuggestions()
    }

    func isFavorite(_ callsign: String) -> Bool {
        let normalized = Self.normalizeCandidate(callsign)
        return !normalized.isEmpty && (baseFavorites.contains(normalized) || userFavorites.contains(normalized))
    }

    func registerAliasEvidence(between lhs: String, and rhs: String, source: DestinationAliasEvidence) {
        let left = Self.normalizeComparisonKey(lhs)
        let right = Self.normalizeComparisonKey(rhs)
        guard !left.isEmpty, !right.isEmpty, left != right else { return }

        let key = AliasKey(left, right)
        aliasEvidence[key, default: []].insert(source)
        persistAliasEvidence()
        updateValidationAndSuggestions()
    }

    func removeAliasLink(between lhs: String, and rhs: String) {
        let left = Self.normalizeComparisonKey(lhs)
        let right = Self.normalizeComparisonKey(rhs)
        guard !left.isEmpty, !right.isEmpty, left != right else { return }
        aliasEvidence.removeValue(forKey: AliasKey(left, right))
        persistAliasEvidence()
        updateValidationAndSuggestions()
    }

    func hasAliasLink(between lhs: String, and rhs: String) -> Bool {
        let left = Self.normalizeComparisonKey(lhs)
        let right = Self.normalizeComparisonKey(rhs)
        guard !left.isEmpty, !right.isEmpty, left != right else { return false }
        return hasEvidence(for: AliasKey(left, right))
    }

    func linkedAlias(for value: String) -> String? {
        let normalized = Self.normalizeComparisonKey(value)
        guard !normalized.isEmpty else { return nil }

        let links = aliasEvidence
            .filter { hasEvidence(for: $0.key) && ($0.key.left == normalized || $0.key.right == normalized) }
            .map { $0.key.left == normalized ? $0.key.right : $0.key.left }
            .sorted()

        return links.first
    }

    static func sanitizeForTyping(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789- ")
        let upper = raw.uppercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : nil }
        let filtered = String(upper.compactMap { $0 })

        let collapsed = filtered.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeCandidate(_ raw: String) -> String {
        sanitizeForTyping(raw)
            .replacingOccurrences(of: " ", with: "")
    }

    static func validateCandidate(_ raw: String) -> DestinationValidationState {
        let normalized = normalizeCandidate(raw)
        guard !normalized.isEmpty else { return .empty }

        let pattern = #"^[A-Z0-9]{1,6}(?:-(?:[0-9]|1[0-5]))?$"#
        guard normalized.range(of: pattern, options: .regularExpression) != nil else {
            return .invalid("Use CALL or CALL-SSID (SSID 0-15).")
        }

        guard normalized.rangeOfCharacter(from: .letters) != nil else {
            return .invalid("Callsign must include at least one letter.")
        }

        return .valid(normalized)
    }

    static func rankedSuggestions(query: String, candidates: [String]) -> [String] {
        let normalizedQuery = normalizeCandidate(query)
        var seen = Set<String>()
        let deduped = candidates
            .map(normalizeCandidate)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }

        guard !normalizedQuery.isEmpty else { return deduped }

        return deduped
            .map { candidate -> (String, Int) in
                let prefixScore = candidate.hasPrefix(normalizedQuery) ? 0 : 1
                let containsScore = candidate.contains(normalizedQuery) ? 0 : 2
                let lengthDelta = abs(candidate.count - normalizedQuery.count)
                return (candidate, prefixScore * 100 + containsScore * 10 + lengthDelta)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0 < rhs.0
            }
            .map(\.0)
    }

    private static func normalizeComparisonKey(_ value: String) -> String {
        let normalized = normalizeCandidate(value)
        guard !normalized.isEmpty else { return "" }
        guard let dash = normalized.lastIndex(of: "-") else { return normalized }
        let suffix = normalized[normalized.index(after: dash)...]
        if suffix == "0" {
            return String(normalized[..<dash])
        }
        return normalized
    }

    private func updateValidationAndSuggestions() {
        validationState = Self.validateCandidate(typedText)
        visibleSections = buildSections()
        didYouMeanRow = buildDidYouMeanRow()

        if let current = highlightedSuggestionID,
           flattenedRowsIncludingDidYouMean().contains(where: { $0.id == current }) {
            return
        }

        highlightedSuggestionID = flattenedRowsIncludingDidYouMean().first?.id
    }

    private func buildSections() -> [DestinationSuggestionSection] {
        let query = Self.normalizeCandidate(typedText)

        let effectiveFavorites = dedupeNormalized(Array(baseFavorites) + Array(userFavorites))
        let favoritesRows = buildRows(
            values: effectiveFavorites,
            section: .favorites,
            query: query,
            fallbackSecondary: "Favorited destination"
        )

        let recentRows = buildRows(
            values: recentValues,
            section: .recent,
            query: query,
            fallbackSecondary: "Recently heard"
        )

        let neighborRows = buildRows(
            values: neighborValues,
            section: .neighbors,
            query: query,
            fallbackSecondary: "Neighbor node"
        )

        let sections = [
            DestinationSuggestionSection(id: DestinationSuggestionRow.Section.favorites.rawValue, title: DestinationSuggestionRow.Section.favorites.title, rows: favoritesRows),
            DestinationSuggestionSection(id: DestinationSuggestionRow.Section.recent.rawValue, title: DestinationSuggestionRow.Section.recent.title, rows: recentRows),
            DestinationSuggestionSection(id: DestinationSuggestionRow.Section.neighbors.rawValue, title: DestinationSuggestionRow.Section.neighbors.title, rows: neighborRows)
        ]

        return sections.filter { !$0.rows.isEmpty }
    }

    private func buildRows(
        values: [String],
        section: DestinationSuggestionRow.Section,
        query: String,
        fallbackSecondary: String
    ) -> [DestinationSuggestionRow] {
        let ranked = Self.rankedSuggestions(query: query, candidates: values)
        guard !ranked.isEmpty else { return [] }

        return ranked.map { candidate in
            let alias = linkedAlias(for: candidate)
            let aliasText = alias.map { "aka \($0)" }
            return DestinationSuggestionRow(
                callsign: candidate,
                secondaryText: aliasText ?? fallbackSecondary,
                section: section,
                isFavorite: isFavorite(candidate),
                aliasText: aliasText
            )
        }
    }

    private func buildDidYouMeanRow() -> DestinationSuggestionRow? {
        guard case let .valid(value) = validationState else { return nil }
        let matchExists = visibleSections.flatMap(\.rows).contains { $0.callsign == value }
        guard !matchExists else { return nil }

        guard let alias = linkedAlias(for: value) else { return nil }

        return DestinationSuggestionRow(
            callsign: alias,
            secondaryText: "Did you mean \(alias)?",
            section: .recent,
            isFavorite: isFavorite(alias),
            aliasText: "aka \(value)"
        )
    }

    private func flattenedRowsIncludingDidYouMean() -> [DestinationSuggestionRow] {
        var rows = visibleSections.flatMap(\.rows)
        if let didYouMeanRow {
            rows.append(didYouMeanRow)
        }
        return rows
    }

    private func highlightedRow() -> DestinationSuggestionRow? {
        guard let id = highlightedSuggestionID else { return nil }
        return flattenedRowsIncludingDidYouMean().first { $0.id == id }
    }

    private func resolveCommit(for value: String) -> String? {
        let normalized = Self.normalizeCandidate(value)
        guard !normalized.isEmpty else { return nil }

        if case let .valid(candidate) = Self.validateCandidate(normalized) {
            return candidate
        }

        if let alias = linkedAlias(for: normalized), case let .valid(candidate) = Self.validateCandidate(alias) {
            return candidate
        }

        return nil
    }

    private func applySelection(_ value: String) {
        let normalized = Self.normalizeCandidate(value)
        guard !normalized.isEmpty else { return }
        typedText = normalized
        selectedStation = normalized
        validationState = .valid(normalized)
        isPopoverPresented = false
    }

    private func dedupeNormalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map(Self.normalizeCandidate)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private func hasEvidence(for key: AliasKey) -> Bool {
        guard let sources = aliasEvidence[key] else { return false }
        return !sources.isEmpty
    }

    private func loadPersistedFavorites() {
        let values = defaults.array(forKey: favoritesDefaultsKey) as? [String] ?? []
        userFavorites = Set(values.map(Self.normalizeCandidate).filter { !$0.isEmpty })
    }

    private func persistFavorites() {
        defaults.set(Array(userFavorites).sorted(), forKey: favoritesDefaultsKey)
    }

    private func loadPersistedAliasEvidence() {
        guard let data = defaults.data(forKey: aliasDefaultsKey),
              let decoded = try? JSONDecoder().decode([PersistedAliasLink].self, from: data) else {
            aliasEvidence = [:]
            return
        }

        aliasEvidence = decoded.reduce(into: [:]) { partial, entry in
            let key = AliasKey(entry.left, entry.right)
            partial[key] = Set(entry.evidence.map(\.value))
        }
    }

    private func persistAliasEvidence() {
        let codable = aliasEvidence
            .map { key, evidence in
                PersistedAliasLink(
                    left: key.left,
                    right: key.right,
                    evidence: Array(evidence).sorted { $0.rank < $1.rank }.map(DestinationAliasEvidenceCodable.init)
                )
            }
            .sorted { lhs, rhs in
                if lhs.left != rhs.left { return lhs.left < rhs.left }
                return lhs.right < rhs.right
            }
        if let data = try? JSONEncoder().encode(codable) {
            defaults.set(data, forKey: aliasDefaultsKey)
        }
    }
}

private struct DestinationAliasEvidenceCodable: Codable {
    let rawValue: String

    init(_ value: DestinationAliasEvidence) {
        self.rawValue = value.rawValue
    }

    var value: DestinationAliasEvidence {
        DestinationAliasEvidence(rawValue: rawValue) ?? .digipeatReference
    }
}

private extension DestinationAliasEvidence {
    var rawValue: String {
        switch self {
        case .digipeatReference: return "digipeatReference"
        case .nodeIdentifier: return "nodeIdentifier"
        case .userConfirmed: return "userConfirmed"
        }
    }

    var rank: Int {
        switch self {
        case .digipeatReference: return 0
        case .nodeIdentifier: return 1
        case .userConfirmed: return 2
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "digipeatReference": self = .digipeatReference
        case "nodeIdentifier": self = .nodeIdentifier
        case "userConfirmed": self = .userConfirmed
        default: return nil
        }
    }
}
