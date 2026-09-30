import Foundation

/// The operator's manual PACLEN, K and N2, as stored.
///
/// Each is nil while its parameter is left on Auto. These used to live only
/// in the Packet Node page's own copy of the adaptive settings, so they were
/// lost at every launch, and opening the page pushed that copy's defaults
/// over whatever the operator had set.
nonisolated struct AX25LinkTuning: Codable, Equatable, Sendable {
    var paclen: Int?
    var windowSize: Int?
    var maxRetries: Int?

    static let storageKey = "ax25.linkTuning.v1"

    init(paclen: Int? = nil, windowSize: Int? = nil, maxRetries: Int? = nil) {
        self.paclen = paclen
        self.windowSize = windowSize
        self.maxRetries = maxRetries
    }

    /// Reads the manual values out of a full set of adaptive settings.
    init(_ settings: TxAdaptiveSettings) {
        paclen = settings.paclen.mode == .manual ? settings.paclen.manualValue : nil
        windowSize = settings.windowSize.mode == .manual ? settings.windowSize.manualValue : nil
        maxRetries = settings.maxRetries.mode == .manual ? settings.maxRetries.manualValue : nil
    }

    /// Puts the stored choices onto a set of adaptive settings, leaving
    /// everything else, including what has been learned, as it was.
    func applied(to settings: TxAdaptiveSettings) -> TxAdaptiveSettings {
        var result = settings
        Self.apply(paclen, to: &result.paclen)
        Self.apply(windowSize, to: &result.windowSize)
        Self.apply(maxRetries, to: &result.maxRetries)
        return result
    }

    private static func apply(_ value: Int?, to setting: inout AdaptiveSetting<Int>) {
        if let value {
            setting.mode = .manual
            setting.manualValue = setting.range.map { min(max(value, $0.lowerBound), $0.upperBound) } ?? value
        } else {
            setting.mode = .auto
        }
    }
}

extension AppSettingsStore {
    /// Manual link-layer parameters. Read at launch and when the Packet Node
    /// page opens, written when the operator changes one.
    var ax25LinkTuning: AX25LinkTuning {
        get {
            guard let data = defaults.data(forKey: AX25LinkTuning.storageKey),
                  let tuning = try? JSONDecoder().decode(AX25LinkTuning.self, from: data)
            else { return AX25LinkTuning() }
            return tuning
        }
        set {
            guard newValue != ax25LinkTuning else { return }
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: AX25LinkTuning.storageKey)
            }
        }
    }
}
