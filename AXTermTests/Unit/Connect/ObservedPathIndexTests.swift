import XCTest
@testable import AXTerm

/// The connect bar's observed paths, rebuilt from every stored packet a
/// moment after each burst of traffic. Each packet's digipeaters and peers
/// were normalized and validated again, about 350 ms on the main thread with
/// 9,000 packets, which froze the Terminal page every few seconds on a busy
/// APRS channel (2026-10-10). Each distinct callsign is now judged once per
/// rebuild.
final class ObservedPathIndexTests: XCTestCase {

    private func packet(from: String, to: String, via: [String], at seconds: Double) -> Packet {
        Packet(timestamp: Date(timeIntervalSince1970: seconds),
               from: AX25Address(call: from), to: AX25Address(call: to),
               via: via.map { AX25Address(call: $0, repeated: true) },
               info: Data("x".utf8))
    }

    func testEachDistinctCallsignIsJudgedOnce() {
        var packets: [Packet] = []
        for i in 0..<600 {
            packets.append(packet(from: ["N0AMY", "WA6IFI", "K0PWO"][i % 3], to: "APRS",
                                  via: ["W0NED", "WIDE2"], at: Double(i)))
        }
        var canonicalCalls = 0, digiCalls = 0
        let result = ObservedPathIndex.build(packets,
                                             canonical: { canonicalCalls += 1; return $0.uppercased() },
                                             isDigi: { digiCalls += 1; return $0 != "WIDE2" })
        XCTAssertLessThanOrEqual(canonicalCalls, 6, "W0NED, WIDE2, APRS and three senders")
        XCTAssertLessThanOrEqual(digiCalls, 2)
        XCTAssertEqual(result.knownDigis, ["W0NED"])
        // Each sender and the destination, via W0NED.
        XCTAssertEqual(Set(result.paths.map(\.peer)), ["N0AMY", "WA6IFI", "K0PWO", "APRS"])
        XCTAssertEqual(result.paths.first { $0.peer == "APRS" }?.count, 600)
        XCTAssertEqual(result.paths.first { $0.peer == "N0AMY" }?.lastSeen, Date(timeIntervalSince1970: 597))
    }

    func testAPacketWithNoDigipeaterAddsNothing() {
        let result = ObservedPathIndex.build([packet(from: "N0AMY", to: "APRS", via: [], at: 0)],
                                             canonical: { $0 }, isDigi: { _ in true })
        XCTAssertTrue(result.paths.isEmpty)
        XCTAssertTrue(result.knownDigis.isEmpty)
    }
}
