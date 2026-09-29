import Foundation

nonisolated enum ConnectCallsign {
    static func normalize(_ raw: String) -> String {
        CallsignValidator.normalize(raw)
    }

    static func isValidSSIDCall(_ raw: String) -> Bool {
        guard let call = Callsign(raw) else { return false }
        return CallsignValidator.isValidCallsign(call.stringValue)
    }

    static func toCallsign(_ raw: String) -> CallsignSSID? {
        Callsign(raw)
    }
}

nonisolated enum DigipeaterListParser {
    static let maxDigipeaters = 8

    static func parse(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { CallsignValidator.normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    static func parseValid(_ raw: String) -> [CallsignSSID] {
        parse(raw)
            .compactMap { ConnectCallsign.toCallsign($0) }
            .prefix(maxDigipeaters)
            .map { $0 }
    }

    static func capped(_ values: [String]) -> [String] {
        Array(values.prefix(maxDigipeaters))
    }

    /// Normalization used for duplicate comparison only.
    /// - Trims whitespace
    /// - Uppercases
    /// - Treats CALL and CALL-0 as equivalent
    static func normalizeForComparison(_ raw: String) -> String {
        let normalized = CallsignValidator.normalize(raw)
        guard !normalized.isEmpty else { return "" }

        guard let dash = normalized.lastIndex(of: "-"), dash < normalized.endIndex else {
            return normalized
        }
        let ssidStart = normalized.index(after: dash)
        guard ssidStart < normalized.endIndex else { return normalized }
        let ssidPart = normalized[ssidStart...]
        guard ssidPart.allSatisfy(\.isNumber), let ssid = Int(ssidPart), ssid == 0 else {
            return normalized
        }
        return String(normalized[..<dash])
    }

    static func firstDuplicate(in incoming: [String], existing: [String]) -> String? {
        var seen = Set(existing.map(normalizeForComparison))
        for raw in incoming {
            let key = normalizeForComparison(raw)
            guard !key.isEmpty else { continue }
            if !seen.insert(key).inserted {
                return CallsignValidator.normalize(raw)
            }
        }
        return nil
    }

    static func dedupedPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let display = CallsignValidator.normalize(raw)
            guard !display.isEmpty else { continue }
            let key = normalizeForComparison(display)
            guard !key.isEmpty else { continue }
            if seen.insert(key).inserted {
                result.append(display)
            }
        }
        return result
    }
}

nonisolated struct ConnectAttemptRecord: Codable, Equatable {
    let to: String
    let mode: ConnectBarMode
    let timestamp: Date
    let success: Bool
    let digis: [String]
    let nextHopOverride: String?

    init(
        to: String,
        mode: ConnectBarMode,
        timestamp: Date,
        success: Bool,
        digis: [String] = [],
        nextHopOverride: String? = nil
    ) {
        self.to = CallsignValidator.normalize(to)
        self.mode = mode
        self.timestamp = timestamp
        self.success = success
        self.digis = digis.map { CallsignValidator.normalize($0) }
        self.nextHopOverride = nextHopOverride.map { CallsignValidator.normalize($0) }
    }

    var result: ConnectAttemptResult {
        success ? .success : .failed
    }

    private enum CodingKeys: String, CodingKey {
        case to
        case mode
        case timestamp
        case success
        case digis
        case nextHopOverride
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = CallsignValidator.normalize(try container.decode(String.self, forKey: .to))
        mode = try container.decode(ConnectBarMode.self, forKey: .mode)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        if let explicit = try container.decodeIfPresent(Bool.self, forKey: .success) {
            success = explicit
        } else {
            let legacyResult = try container.decodeIfPresent(ConnectAttemptResult.self, forKey: .result) ?? .failed
            success = legacyResult == .success
        }
        digis = (try container.decodeIfPresent([String].self, forKey: .digis) ?? [])
            .map { CallsignValidator.normalize($0) }
        if let override = try container.decodeIfPresent(String.self, forKey: .nextHopOverride) {
            let normalized = CallsignValidator.normalize(override)
            nextHopOverride = normalized.isEmpty ? nil : normalized
        } else {
            nextHopOverride = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(to, forKey: .to)
        try container.encode(mode, forKey: .mode)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(success, forKey: .success)
        try container.encode(digis, forKey: .digis)
        try container.encodeIfPresent(nextHopOverride, forKey: .nextHopOverride)
        try container.encode(result, forKey: .result)
    }
}

typealias ConnectAttempt = ConnectAttemptRecord

nonisolated struct RecentDigiPath: Codable, Hashable {
    let path: [String]
    let mode: ConnectBarMode
    let context: ConnectSourceContext?
    let timestamp: Date

    init(path: [String], mode: ConnectBarMode, context: ConnectSourceContext?, timestamp: Date) {
        self.path = path
        self.mode = mode
        self.context = context
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case mode
        case context
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode([String].self, forKey: .path)
        mode = try container.decodeIfPresent(ConnectBarMode.self, forKey: .mode) ?? .ax25ViaDigi
        context = try container.decodeIfPresent(ConnectSourceContext.self, forKey: .context)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }
}

nonisolated struct ConnectModeContextDefaults: Codable {
    var values: [ConnectSourceContext: ConnectBarMode]
}
