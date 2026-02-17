import Foundation
import Combine

typealias AdaptiveSessionID = String

nonisolated struct AdaptiveETXSample: Sendable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let etx: Double

    init(timestamp: Date, etx: Double) {
        self.id = UUID()
        self.timestamp = timestamp
        self.etx = etx
    }
}

nonisolated struct AdaptiveRingBuffer<Element: Sendable>: Sendable {
    let capacity: Int
    private(set) var storage: [Element]

    init(capacity: Int, storage: [Element] = []) {
        self.capacity = max(1, capacity)
        self.storage = Array(storage.suffix(max(1, capacity)))
    }

    var elements: [Element] { storage }
    var isEmpty: Bool { storage.isEmpty }
    var last: Element? { storage.last }

    mutating func append(_ element: Element) {
        storage.append(element)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    mutating func removeAll(where shouldRemove: (Element) -> Bool) {
        storage.removeAll(where: shouldRemove)
    }

    mutating func replaceLast(with element: Element) {
        guard !storage.isEmpty else {
            append(element)
            return
        }
        storage[storage.count - 1] = element
    }
}

nonisolated struct AdaptiveParams: Sendable, Equatable {
    let k: Int
    let p: Int
    let n2: Int
    let rtoMin: Double
    let rtoMax: Double
    let currentRto: Double?
    let lossRate: Double?
    let etx: Double?
    let srtt: Double?
    let qualityLabel: String
    let updatedAt: Date
    let destination: String?
    let pathSignature: String?
}

final class AdaptiveStatusStore: ObservableObject {
    @Published var globalAdaptive: AdaptiveParams?
    @Published var sessionAdaptiveByID: [AdaptiveSessionID: AdaptiveParams] = [:]
    @Published var selectedSessionID: AdaptiveSessionID?
    @Published var globalETXHistory = AdaptiveRingBuffer<AdaptiveETXSample>(capacity: 900)
    @Published var sessionETXHistoryByID: [AdaptiveSessionID: AdaptiveRingBuffer<AdaptiveETXSample>] = [:]

    private let globalWindow: TimeInterval = 30 * 60
    private let sessionWindow: TimeInterval = 10 * 60
    private let minSampleSpacing: TimeInterval = 2

    /// Explicit nonisolated deinit to avoid Swift concurrency runtime bug
    /// where isolated deallocating deinit triggers task-local scope corruption.
    nonisolated deinit {}

    var effectiveAdaptive: AdaptiveParams? {
        if let selectedSessionID, let session = sessionAdaptiveByID[selectedSessionID] {
            return session
        }
        return globalAdaptive
    }

    var effectiveETXHistory: [AdaptiveETXSample] {
        if let selectedSessionID, let history = sessionETXHistoryByID[selectedSessionID] {
            return trimToWindow(history.elements, window: sessionWindow)
        }
        return trimToWindow(globalETXHistory.elements, window: globalWindow)
    }

    func setSelectedSession(id: AdaptiveSessionID?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setSelectedSession(id: id) }
            return
        }
        selectedSessionID = id
    }

    func updateGlobal(settings: TxAdaptiveSettings, lossRate: Double?, etx: Double?, srtt: Double?, updatedAt: Date = Date()) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateGlobal(settings: settings, lossRate: lossRate, etx: etx, srtt: srtt, updatedAt: updatedAt)
            }
            return
        }
        globalAdaptive = AdaptiveParams(
            k: settings.windowSize.effectiveValue,
            p: settings.paclen.effectiveValue,
            n2: settings.maxRetries.effectiveValue,
            rtoMin: settings.rtoMin.effectiveValue,
            rtoMax: settings.rtoMax.effectiveValue,
            currentRto: settings.currentRto,
            lossRate: lossRate,
            etx: etx,
            srtt: srtt,
            qualityLabel: settings.windowSize.displayReason ?? settings.paclen.displayReason ?? "Adaptive",
            updatedAt: updatedAt,
            destination: nil,
            pathSignature: nil
        )
        if let etx {
            appendSample(
                AdaptiveETXSample(timestamp: updatedAt, etx: etx),
                into: &globalETXHistory,
                window: globalWindow
            )
        }
    }

    func refreshGlobalSettings(_ settings: TxAdaptiveSettings, updatedAt: Date = Date()) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.refreshGlobalSettings(settings, updatedAt: updatedAt)
            }
            return
        }
        globalAdaptive = AdaptiveParams(
            k: settings.windowSize.effectiveValue,
            p: settings.paclen.effectiveValue,
            n2: settings.maxRetries.effectiveValue,
            rtoMin: settings.rtoMin.effectiveValue,
            rtoMax: settings.rtoMax.effectiveValue,
            currentRto: settings.currentRto,
            lossRate: globalAdaptive?.lossRate,
            etx: globalAdaptive?.etx,
            srtt: globalAdaptive?.srtt,
            qualityLabel: settings.windowSize.displayReason ?? settings.paclen.displayReason ?? "Adaptive",
            updatedAt: updatedAt,
            destination: nil,
            pathSignature: nil
        )
    }

    func updateSession(
        id: AdaptiveSessionID,
        destination: String,
        pathSignature: String,
        settings: TxAdaptiveSettings,
        lossRate: Double?,
        etx: Double?,
        srtt: Double?,
        updatedAt: Date = Date()
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateSession(
                    id: id,
                    destination: destination,
                    pathSignature: pathSignature,
                    settings: settings,
                    lossRate: lossRate,
                    etx: etx,
                    srtt: srtt,
                    updatedAt: updatedAt
                )
            }
            return
        }
        sessionAdaptiveByID[id] = AdaptiveParams(
            k: settings.windowSize.effectiveValue,
            p: settings.paclen.effectiveValue,
            n2: settings.maxRetries.effectiveValue,
            rtoMin: settings.rtoMin.effectiveValue,
            rtoMax: settings.rtoMax.effectiveValue,
            currentRto: settings.currentRto,
            lossRate: lossRate,
            etx: etx,
            srtt: srtt,
            qualityLabel: settings.windowSize.displayReason ?? settings.paclen.displayReason ?? "Adaptive",
            updatedAt: updatedAt,
            destination: destination,
            pathSignature: pathSignature
        )

        if let etx {
            var history = sessionETXHistoryByID[id] ?? AdaptiveRingBuffer<AdaptiveETXSample>(capacity: 400)
            appendSample(
                AdaptiveETXSample(timestamp: updatedAt, etx: etx),
                into: &history,
                window: sessionWindow
            )
            sessionETXHistoryByID[id] = history
        }
    }

    func removeSession(id: AdaptiveSessionID) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.removeSession(id: id) }
            return
        }
        sessionAdaptiveByID.removeValue(forKey: id)
        sessionETXHistoryByID.removeValue(forKey: id)
        if selectedSessionID == id {
            selectedSessionID = nil
        }
    }

    private func appendSample(_ sample: AdaptiveETXSample, into history: inout AdaptiveRingBuffer<AdaptiveETXSample>, window: TimeInterval) {
        let cutoff = sample.timestamp.addingTimeInterval(-window)
        history.removeAll { $0.timestamp < cutoff }

        if let last = history.last, sample.timestamp.timeIntervalSince(last.timestamp) < minSampleSpacing {
            history.replaceLast(with: sample)
            return
        }
        history.append(sample)
    }

    private func trimToWindow(_ samples: [AdaptiveETXSample], window: TimeInterval) -> [AdaptiveETXSample] {
        guard let latest = samples.last else { return [] }
        let cutoff = latest.timestamp.addingTimeInterval(-window)
        return samples.filter { $0.timestamp >= cutoff }
    }
}
