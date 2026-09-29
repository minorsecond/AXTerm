import XCTest
@testable import AXTerm

/// p-persistence, replayable: the same seed makes the same decisions.
final class ChannelAccessTests: XCTestCase {

    private typealias Access = ChannelAccess<SplitMix64>

    private func parameters(persist: UInt8 = 63, slot: Int = 4800, dwait: Int = 0,
                            fullDuplex: Bool = false, maxWait: Int = 480_000) -> Access.Parameters {
        .init(slotTimeSamples: slot, persist: persist, dwaitSamples: dwait, fullDuplex: fullDuplex, maxWaitSamples: maxWait)
    }

    /// Run until a terminal decision; returns the trace and the sample it ended at.
    private func run(_ access: inout Access, from start: Int64, dcd: (Int64) -> Bool,
                     limit: Int64 = 1_000_000) -> (decisions: [Access.Decision], endedAt: Int64) {
        var now = start
        var trace: [Access.Decision] = []
        while now < start + limit {
            let d = access.evaluate(now: now, dcd: dcd(now))
            trace.append(d)
            switch d {
            case .transmit, .gaveUp, .idle: return (trace, now)
            case .waiting(let next): now = max(now + 1, next)
            }
        }
        return (trace, now)
    }

    func testIdleWithoutARequest() {
        var access = Access(parameters: parameters(), rng: SplitMix64(seed: 1))
        XCTAssertEqual(access.evaluate(now: 0, dcd: false), .idle)
        XCTAssertFalse(access.isRequesting)
    }

    func testTheSameSeedGivesTheSameTrace() {
        var a = Access(parameters: parameters(), rng: SplitMix64(seed: 42))
        var b = Access(parameters: parameters(), rng: SplitMix64(seed: 42))
        a.requestChannel(now: 0); b.requestChannel(now: 0)
        let ra = run(&a, from: 0) { _ in false }
        let rb = run(&b, from: 0) { _ in false }
        XCTAssertEqual(ra.decisions, rb.decisions)
        XCTAssertEqual(ra.endedAt, rb.endedAt)
    }

    /// Persist 63 is one chance in four per slot: over many trials the first
    /// slot transmits about a quarter of the time.
    func testPersistSixtyThreeTransmitsInAboutAQuarterOfFirstSlots() {
        var firstSlot = 0
        for seed in 0..<10_000 {
            var access = Access(parameters: parameters(), rng: SplitMix64(seed: UInt64(seed)))
            access.requestChannel(now: 0)
            if access.evaluate(now: 0, dcd: false) == .transmit { firstSlot += 1 }
        }
        XCTAssertEqual(Double(firstSlot) / 10_000, 0.25, accuracy: 0.02)
    }

    func testPersistTwoFiftyFiveTransmitsInTheFirstClearSlot() {
        var access = Access(parameters: parameters(persist: 255), rng: SplitMix64(seed: 3))
        access.requestChannel(now: 100)
        XCTAssertEqual(access.evaluate(now: 100, dcd: false), .transmit)
        XCTAssertFalse(access.isRequesting)
    }

    func testABusyChannelNeverTransmits() {
        var access = Access(parameters: parameters(persist: 255), rng: SplitMix64(seed: 4))
        access.requestChannel(now: 0)
        for now in stride(from: Int64(0), to: 100_000, by: 480) {
            XCTAssertNotEqual(access.evaluate(now: now, dcd: true), .transmit)
        }
        // The moment it clears, persist 255 goes.
        XCTAssertEqual(access.evaluate(now: 100_000, dcd: false), .transmit)
    }

    func testDWAITIsHonouredAfterTheChannelClears() {
        var access = Access(parameters: parameters(persist: 255, dwait: 960), rng: SplitMix64(seed: 5))
        access.requestChannel(now: 0)
        XCTAssertEqual(access.evaluate(now: 0, dcd: true), .waiting(nextCheck: 1))
        XCTAssertEqual(access.evaluate(now: 1000, dcd: false), .waiting(nextCheck: 1960), "DWAIT from the clear")
        XCTAssertEqual(access.evaluate(now: 1500, dcd: false), .waiting(nextCheck: 1960))
        XCTAssertEqual(access.evaluate(now: 1960, dcd: false), .transmit)
    }

    /// An RNG that always rolls the same byte, so a slot's outcome is chosen.
    private struct FixedRNG: RandomNumberGenerator {
        let value: UInt64
        mutating func next() -> UInt64 { value }
    }

    func testSlotsAreSpacedBySlotTime() {
        // Every roll is 200: above persist 63, so every slot waits.
        var access = ChannelAccess(parameters: parameters(persist: 63, slot: 4800), rng: FixedRNG(value: 200))
        access.requestChannel(now: 0)
        let first = access.evaluate(now: 0, dcd: false)
        guard case .waiting(let next) = first else { return XCTFail("expected to wait, got \(first)") }
        XCTAssertEqual(next, 4800)
        XCTAssertEqual(access.evaluate(now: 2400, dcd: false), .waiting(nextCheck: 4800), "between slots, nothing is rolled")
    }

    func testGivesUpAfterMaxWait() {
        var access = Access(parameters: parameters(persist: 255, maxWait: 48_000), rng: SplitMix64(seed: 7))
        access.requestChannel(now: 0)
        for now in stride(from: Int64(0), through: 48_000, by: 480) {
            XCTAssertNotEqual(access.evaluate(now: now, dcd: true), .gaveUp, "at \(now)")
        }
        XCTAssertEqual(access.evaluate(now: 48_001, dcd: true), .gaveUp)
        XCTAssertFalse(access.isRequesting)
    }

    func testFullDuplexTransmitsAtOnceEvenWhenBusy() {
        var access = Access(parameters: parameters(persist: 0, fullDuplex: true), rng: SplitMix64(seed: 8))
        access.requestChannel(now: 0)
        XCTAssertEqual(access.evaluate(now: 0, dcd: true), .transmit)
    }

    func testParametersFromConfigurationUseTheSampleRate() {
        var config = SoftModemConfiguration()
        config.slotTimeMs = 100
        config.dwaitMs = 20
        config.maxChannelWaitSeconds = 5
        let p = Access.Parameters(sampleRate: 48_000, configuration: config)
        XCTAssertEqual(p.slotTimeSamples, 4800)
        XCTAssertEqual(p.dwaitSamples, 960)
        XCTAssertEqual(p.maxWaitSamples, 240_000)
        XCTAssertEqual(p.persist, 63)
    }
}
