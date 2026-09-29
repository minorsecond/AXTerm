import GRDB
import XCTest
@testable import AXTerm

/// Frames this station sent are kept, the same way frames it heard are.
///
/// Until 2026-09-17 they were not. The operator's live database held 863
/// packets and every one of them was `rx`: a transmission left a line of
/// console text and an entry in an in-memory ring buffer that died with the
/// process, so after a restart there was no way to answer whether a beacon
/// had gone out, or when.
final class TransmittedPacketLogTests: XCTestCase {

    private func makeStore() throws -> SQLitePacketStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLitePacketStore(dbQueue: queue)
    }

    private func packet(_ direction: Packet.Direction) -> Packet {
        Packet(timestamp: Date(),
               from: AX25Address(call: "K0EPI", ssid: 5),
               to: AX25Address(call: "APZAXT"),
               via: [AX25Address(call: "WIDE1", ssid: 1)],
               frameType: .u,
               control: 0x03,
               pid: 0xF0,
               info: Data("!3936.75N/10443.97W-".utf8),
               rawAx25: Data([0x82, 0xA0, 0xB4, 0x82, 0xA8, 0xA8, 0x60]),
               direction: direction)
    }

    /// Everything that was storing packets before keeps storing them as
    /// received, without being changed to say so.
    func testAPacketIsReceivedUnlessItSaysOtherwise() {
        XCTAssertEqual(Packet().direction, .rx)
        XCTAssertEqual(PacketRecord(packet: packet(.rx)).direction, "rx")
    }

    func testATransmittedFrameIsStoredAndComesBackAsTransmitted() throws {
        let store = try makeStore()
        let sent = packet(.tx)
        try store.save(sent)
        try store.save(packet(.rx))

        let all = try store.loadRecent(limit: 10)
        XCTAssertEqual(all.count, 2)

        let transmitted = try XCTUnwrap(all.first { $0.id == sent.id })
        XCTAssertEqual(transmitted.direction, "tx",
                       "a frame we sent must not read back as one we heard")
        XCTAssertEqual(transmitted.fromCall, "K0EPI")
        XCTAssertEqual(transmitted.fromSSID, 5)
        XCTAssertEqual(all.filter { $0.direction == "rx" }.count, 1)
    }

    /// The column is what the Packets view and every analytics query filter
    /// on, so the stored string matters, not just the enum.
    func testTheStoredColumnSaysTx() throws {
        XCTAssertEqual(PacketRecord(packet: packet(.tx)).direction, "tx")
        XCTAssertEqual(Packet.Direction.tx.rawValue, "tx")
        XCTAssertEqual(Packet.Direction.rx.rawValue, "rx")
    }
}
