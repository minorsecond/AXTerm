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
}

nonisolated struct ConnectAttemptRecord: Codable, Equatable {
    let to: String
    let mode: ConnectBarMode
    let timestamp: Date
    let result: ConnectAttemptResult
}

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
