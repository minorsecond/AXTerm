import XCTest
@testable import AXTerm

/// The sender's own line in the history shows how much of a long message
/// has been acknowledged (retest 2026-10-10, finding 9): the acknowledged
/// part in full color, the rest dimmed. Only for plain text, which the other
/// station reads line by line as it lands; an AXDP message shows there only
/// when it has all arrived, so its line stays evenly dimmed until then.
final class OutgoingLineProgressTests: XCTestCase {

    func testPlainTextDimsWhatIsNotAcknowledgedYet() {
        XCTAssertEqual(ConsoleOutgoingProgress.dimFrom(text: "Hello world", ackedBytes: 6, viaAXDP: false), 6)
        XCTAssertEqual(ConsoleOutgoingProgress.dimFrom(text: "Hello world", ackedBytes: 0, viaAXDP: false), 0)
    }

    /// Bytes are not characters: an acknowledged é is two bytes.
    func testTheCutFallsBetweenCharacters() {
        XCTAssertEqual(ConsoleOutgoingProgress.dimFrom(text: "héllo", ackedBytes: 3, viaAXDP: false), 2)
        XCTAssertEqual(ConsoleOutgoingProgress.dimFrom(text: "héllo", ackedBytes: 2, viaAXDP: false), 1,
                       "half of é is not yet a character")
    }

    func testAnAXDPMessageStaysEvenlyDimmed() {
        XCTAssertEqual(ConsoleOutgoingProgress.dimFrom(text: "Hello world", ackedBytes: 9, viaAXDP: true), 0)
    }

    /// The whole text acknowledged (its CR may still be in flight) dims
    /// nothing.
    func testAllAcknowledgedDimsNothing() {
        XCTAssertNil(ConsoleOutgoingProgress.dimFrom(text: "Hello", ackedBytes: 5, viaAXDP: false))
    }

    /// The line is the newest one we sent to the message's link with the
    /// message's text.
    func testTheLineIsTheNewestOneWeSentWithThatText() {
        let older = ConsoleLine.packet(from: "K0EPI-2", to: "K0EPI-3", text: "Hello", timestamp: Date(timeIntervalSince1970: 1))
        let reply = ConsoleLine.packet(from: "K0EPI-3", to: "K0EPI-2", text: "Hello", timestamp: Date(timeIntervalSince1970: 2))
        let newer = ConsoleLine.packet(from: "K0EPI-2", to: "K0EPI-3", text: "Hello", timestamp: Date(timeIntervalSince1970: 3))
        let other = ConsoleLine.packet(from: "K0EPI-2", to: "W0ARP-1", text: "Hello", timestamp: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(ConsoleOutgoingProgress.lineID(in: [older, reply, newer, other], text: "Hello",
                                                      from: ["K0EPI-2"], to: "K0EPI-3"), newer.id)
        XCTAssertNil(ConsoleOutgoingProgress.lineID(in: [reply], text: "Hello", from: ["K0EPI-2"], to: "K0EPI-3"))
    }
}

#if os(macOS)
import AppKit

/// The Mac table draws it.
@MainActor
final class OutgoingLineRowTests: XCTestCase {
    func testTheRowDimsFromTheCut() {
        let line = ConsoleLine.packet(from: "K0EPI-2", to: "K0EPI-3", text: "Hello world", timestamp: Date())
        var env = ConsoleRowEnvironment()
        env.outgoing = ConsoleOutgoingProgress(lineID: line.id, dimFrom: 6)
        let model = ConsoleRowModel.make(group: ConsoleLineGroup(primary: line), timestampRun: .alone,
                                         beaconRepeat: nil, isExpanded: false, environment: env, fileNameIndex: nil)
        let color = { (index: Int) in model.message.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor }
        XCTAssertEqual(color(0), .labelColor)
        XCTAssertEqual(color(6), .secondaryLabelColor)

        env.outgoing = nil
        let plain = ConsoleRowModel.make(group: ConsoleLineGroup(primary: line), timestampRun: .alone,
                                         beaconRepeat: nil, isExpanded: false, environment: env, fileNameIndex: nil)
        XCTAssertEqual(plain.message.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor, .labelColor)
    }
}
#endif
