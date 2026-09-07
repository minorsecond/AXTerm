import XCTest
@testable import AXTerm

/// The reorder buffer that puts the radio's numbered datagrams back in
/// order, fills brief gaps from retransmits, and gives up on the rest so
/// the stream keeps time.
final class SequenceReorderBufferTests: XCTestCase {

    private func run(_ input: [(UInt16, Int)], hold: Double = 0.1, finalTick: Double? = nil)
    -> (released: [UInt16?], retransmits: [[UInt16]]) {
        var buffer = SequenceReorderBuffer(holdSeconds: hold)
        var released: [UInt16?] = []
        var retransmits: [[UInt16]] = []
        for (seq, atMs) in input {
            buffer.add(sequence: seq, data: Data([UInt8(seq & 0xFF)]), now: Double(atMs) / 1000,
                       release: { s, d in released.append(d == nil ? nil : s) },
                       requestRetransmit: { retransmits.append($0) })
        }
        if let finalTick { buffer.tick(now: finalTick) { s, d in released.append(d == nil ? nil : s) } }
        return (released, retransmits)
    }

    func testInOrderPassesStraightThrough() {
        let (released, retransmits) = run([(10, 0), (11, 10), (12, 20), (13, 30)])
        XCTAssertEqual(released, [10, 11, 12, 13])
        XCTAssertTrue(retransmits.isEmpty)
    }

    func testAnOutOfOrderPacketWaitsThenIsReleasedInOrder() {
        // 11 arrives before 10's neighbour; 12 then 11's slot fills.
        let (released, retransmits) = run([(10, 0), (12, 10), (11, 20)])
        XCTAssertEqual(released, [10, 11, 12], "held 12 until 11 arrived")
        XCTAssertEqual(retransmits.first, [11], "asked for the gap")
    }

    func testAGapOlderThanTheHoldIsGivenUp() {
        // 11 never comes; after the hold, 11 is released as nil and 12 follows.
        let (released, _) = run([(10, 0), (12, 10)], hold: 0.1, finalTick: 0.2)
        XCTAssertEqual(released, [10, nil, 12])
    }

    func testALateDuplicateIsIgnored() {
        let (released, _) = run([(10, 0), (11, 10), (10, 20)])
        XCTAssertEqual(released, [10, 11], "the re-sent 10 is behind and dropped")
    }

    func testSequenceWrapAroundIsHandled() {
        let (released, _) = run([(0xFFFE, 0), (0xFFFF, 10), (0, 20), (1, 30)])
        XCTAssertEqual(released, [0xFFFE, 0xFFFF, 0, 1])
    }
}
