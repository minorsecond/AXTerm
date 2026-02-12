import XCTest
@testable import AXTerm

@MainActor
final class AdaptiveStatusStoreTests: XCTestCase {

    func testEffectiveAdaptivePrefersSelectedSessionWhenAvailable() {
        let store = AdaptiveStatusStore()
        var global = TxAdaptiveSettings()
        global.windowSize.currentAdaptive = 2
        global.paclen.currentAdaptive = 128
        global.maxRetries.currentAdaptive = 15
        store.updateGlobal(settings: global, lossRate: 0.12, etx: 1.6, srtt: nil, updatedAt: Date())

        var session = TxAdaptiveSettings()
        session.windowSize.currentAdaptive = 1
        session.paclen.currentAdaptive = 64
        session.maxRetries.currentAdaptive = 10
        store.updateSession(
            id: "N0HI-7|WIDE1-1",
            destination: "N0HI-7",
            pathSignature: "WIDE1-1",
            settings: session,
            lossRate: 0.22,
            etx: 2.4,
            srtt: nil,
            updatedAt: Date()
        )

        store.setSelectedSession(id: "N0HI-7|WIDE1-1")
        XCTAssertEqual(store.effectiveAdaptive?.k, 1)
        XCTAssertEqual(store.effectiveAdaptive?.p, 64)
        XCTAssertEqual(store.effectiveAdaptive?.n2, 10)

        store.setSelectedSession(id: "UNKNOWN|")
        XCTAssertEqual(store.effectiveAdaptive?.k, 2)
        XCTAssertEqual(store.effectiveAdaptive?.p, 128)
        XCTAssertEqual(store.effectiveAdaptive?.n2, 15)
    }

    func testSessionHistoryIsCappedToTenMinutes() {
        let store = AdaptiveStatusStore()
        let now = Date()

        var settings = TxAdaptiveSettings()
        settings.windowSize.currentAdaptive = 1
        settings.paclen.currentAdaptive = 64
        settings.maxRetries.currentAdaptive = 10

        store.updateSession(
            id: "N0HI-7|",
            destination: "N0HI-7",
            pathSignature: "",
            settings: settings,
            lossRate: 0.2,
            etx: 2.6,
            srtt: nil,
            updatedAt: now.addingTimeInterval(-11 * 60)
        )
        store.updateSession(
            id: "N0HI-7|",
            destination: "N0HI-7",
            pathSignature: "",
            settings: settings,
            lossRate: 0.18,
            etx: 2.1,
            srtt: nil,
            updatedAt: now
        )

        store.setSelectedSession(id: "N0HI-7|")
        let history = store.effectiveETXHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.etx ?? 0, 2.1, accuracy: 0.001)
    }
}
