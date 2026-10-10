#if os(macOS)
import XCTest
import AppKit
@testable import AXTerm

/// The Mac's AppKit console: its update plan, row geometry and row content.
@MainActor
final class ConsoleTableTests: XCTestCase {

    // MARK: Diff

    func testAppendingKeepsEverythingAndInserts() {
        XCTAssertEqual(ConsoleTableDiff.plan(old: [1, 2, 3], new: [1, 2, 3, 4, 5]),
                       .init(removeFront: 0, keep: 3, removeBack: 0, insertBack: 2))
    }

    /// A full console trims its oldest line as a new one arrives.
    func testTrimmingTheFrontWhileAppending() {
        XCTAssertEqual(ConsoleTableDiff.plan(old: [1, 2, 3], new: [2, 3, 4]),
                       .init(removeFront: 1, keep: 2, removeBack: 0, insertBack: 1))
    }

    /// The send status row sits last; a line arriving lands before it.
    func testALineArrivingBeforeTheSendStatus() {
        XCTAssertEqual(ConsoleTableDiff.plan(old: ["a", "b", "status"], new: ["a", "b", "c", "status"]),
                       .init(removeFront: 0, keep: 2, removeBack: 1, insertBack: 2))
    }

    func testNothingInCommonKeepsNothing() {
        XCTAssertEqual(ConsoleTableDiff.plan(old: [1, 2], new: [7, 8]).keep, 0)
        XCTAssertEqual(ConsoleTableDiff.plan(old: [1, 2], new: [Int]()),
                       .init(removeFront: 0, keep: 0, removeBack: 2, insertBack: 0))
        XCTAssertEqual(ConsoleTableDiff.plan(old: [1, 2], new: [1, 2]),
                       .init(removeFront: 0, keep: 2, removeBack: 0, insertBack: 0))
    }

    // MARK: Geometry

    private func aprsLine(_ info: String, from: String = "N0AMY-6", via: [String] = ["WA6IFI-12*", "WIDE2-1"]) -> ConsoleLine {
        ConsoleLine.packet(from: from, to: "APRS", text: info, via: via, radioID: .primary, aprsInfo: Data(info.utf8))
    }

    private func model(_ line: ConsoleLine, env: ConsoleRowEnvironment = ConsoleRowEnvironment(),
                       expanded: Bool = false, duplicates: [ConsoleLine] = []) -> ConsoleRowModel {
        var group = ConsoleLineGroup(primary: line)
        group.duplicates = duplicates
        return ConsoleRowModel.make(group: group, timestampRun: .alone, beaconRepeat: nil, isExpanded: expanded,
                                    environment: env, fileNameIndex: nil)
    }

    private func geometry(_ model: ConsoleRowModel, width: CGFloat) -> ConsoleRowGeometry {
        ConsoleRowGeometry.layout(width: width, measurements: ConsoleRowMeasurements(model: model),
                                  wrapsBelow: model.wrapsBelow, expansionLines: model.expansion.count) {
            ConsoleTextMeasurer.shared.size(of: model.message, width: $0).height
        }
    }

    /// The height shortcut (a message that fits is one line tall) gives the
    /// same height a full layout would, at every width.
    func testTheOneLineShortcutAgreesWithAFullLayout() {
        let row = model(aprsLine("!3953.70N/10505.14W>146.520MHz WWW.TONYTYLER.COM and a longer comment here"))
        for width in stride(from: CGFloat(300), through: 1600, by: 37) {
            let fast = geometry(row, width: width)
            let full = ConsoleTextMeasurer.shared.size(of: row.message, width: fast.messageRect.width).height
            XCTAssertEqual(fast.messageRect.height, full, "width \(width)")
        }
    }

    /// An empty message is one line tall. Measuring one asked the empty
    /// string for its font at index 0, which throws; the park test's YAPP
    /// bytes left empty lines in A's history, and A crashed on every launch
    /// after (2026-10-10).
    func testAnEmptyMessageHasOneLinesHeight() {
        let empty = NSAttributedString(string: "", attributes: [.font: ConsoleRowModel.messageFont])
        let size = ConsoleTextMeasurer.shared.size(of: empty, width: nil)
        XCTAssertEqual(size.width, 0)
        XCTAssertEqual(size.height, ConsoleTextMeasurer.shared.lineHeight(for: ConsoleRowModel.messageFont))
        XCTAssertEqual(ConsoleTextMeasurer.shared.size(of: NSAttributedString(), width: 300).height, size.height)

        let row = model(ConsoleLine.packet(from: "K0EPI-3", to: "K0EPI-4", text: ""))
        XCTAssertGreaterThan(geometry(row, width: 900).height, 0)
    }

    /// The character-count width of a monospaced line matches a real layout,
    /// including the curly quotes, middle dots and degree signs decoded lines
    /// use. Text it cannot vouch for is laid out instead.
    func testTheFixedPitchWidthMatchesALayout() {
        let measurer = ConsoleTextMeasurer.shared
        for sample in ["52.1 mi S \u{00B7} heading 52\u{00B0} \u{00B7} 6,168 ft \u{00B7} \u{201C}WWW.TONYTYLER.COM\u{201D}",
                       "Telemetry #178 \u{00B7} 137, 140, 41, 0, 0 \u{00B7} bits 00010011",
                       "plain ascii line with trailing text", "\u{1F4E1} emoji falls back"] {
            let text = NSAttributedString(string: sample, attributes: [.font: ConsoleRowModel.messageFont])
            let fast = measurer.idealSize(of: text)
            let full = measurer.size(of: text, width: nil)
            XCTAssertEqual(fast.width, full.width, accuracy: 1, sample)
            XCTAssertEqual(fast.height, full.height, sample)
        }
    }

    /// A decoded line that would wrap puts its message under the callsigns,
    /// where it gets the full width.
    func testALongDecodedLineDropsUnderTheCallsigns() {
        let row = model(aprsLine("!3953.70N/10505.14W>" + String(repeating: "word ", count: 30)))
        let wide = geometry(row, width: 4000)
        let narrow = geometry(row, width: 700)
        XCTAssertEqual(wide.messageRect.minY, wide.timestampRect.minY, "fits beside at 4000")
        XCTAssertGreaterThan(narrow.messageRect.minY, narrow.timestampRect.maxY - 1, "drops below at 700")
        // The block (the APRS symbol, then the text) starts under the first callsign.
        XCTAssertEqual(narrow.symbolRect?.minX ?? narrow.messageRect.minX,
                       narrow.timestampRect.maxX + ConsoleRowGeometry.spacing,
                       "starts under the first callsign")
        XCTAssertGreaterThan(narrow.height, wide.height)
    }

    /// A session line wraps beside its header, as it always has.
    func testASessionLineWrapsBesideTheHeader() {
        let line = ConsoleLine.packet(from: "N0CALL", to: "K0EPI-2", text: String(repeating: "listing ", count: 40))
        let row = model(line)
        XCTAssertFalse(row.wrapsBelow)
        let g = geometry(row, width: 700)
        XCTAssertEqual(g.messageRect.minY, g.timestampRect.minY)
        XCTAssertGreaterThan(g.messageRect.minX, g.headerRects.last?.maxX ?? 0)
        XCTAssertGreaterThan(g.messageRect.height, g.timestampRect.height * 2)
    }

    func testAnOpenRowAddsALinePerCopy() {
        let line = aprsLine("!3953.70N/10505.14W>Mobile")
        let dup = aprsLine("!3953.70N/10505.14W>Mobile", via: ["W0NED*", "WIDE1*", "WIDE2-1"])
        let closed = geometry(model(line, duplicates: [dup]), width: 900)
        let open = geometry(model(line, expanded: true, duplicates: [dup]), width: 900)
        XCTAssertEqual(open.height - closed.height, 2 * open.expansionLineHeight + 2, accuracy: 1)
    }

    // MARK: Content

    func testADecodedRowShowsTheShortHeader() {
        let row = model(aprsLine("!3953.70N/10505.14W>Mobile"))
        XCTAssertEqual(row.header.map(\.text), ["N0AMY-6", "WA6IFI-12"])
        XCTAssertNil(row.header.first { $0.text == "APRS" }, "no destination")
        XCTAssertNotNil(row.messageHelp)
        XCTAssertTrue(row.wrapsBelow)
    }

    func testASessionRowKeepsItsFullHeader() {
        let row = model(ConsoleLine.packet(from: "N0CALL", to: "K0EPI-2", text: "hello", via: ["DRLNOD*"]))
        XCTAssertEqual(row.header.map(\.text), ["DRLNOD", "N0CALL", "\u{2192}", "K0EPI-2", ""])
    }

    func testCallsignsAreClickableOnlyWhenTheConsoleLinksThem() {
        var env = ConsoleRowEnvironment()
        XCTAssertNil(model(aprsLine("!3953.70N/10505.14W>x"), env: env).header.first?.callsign)
        env.linksCallsigns = true
        XCTAssertEqual(model(aprsLine("!3953.70N/10505.14W>x"), env: env).header.first?.callsign, "N0AMY-6")
    }

    func testOurCallInTheTextIsPickedOutAndLinksAreLinks() {
        var env = ConsoleRowEnvironment()
        env.localCallsign = "K0EPI"
        env.linksCallsigns = true
        let row = model(aprsLine("!3953.70N/10505.14W>Hi K0EPI-3 see www.example.com", from: "W0NED"), env: env)
        let text = row.message.string as NSString
        let mention = text.range(of: "K0EPI-3")
        XCTAssertNotNil(row.message.attribute(.backgroundColor, at: mention.location, effectiveRange: nil))
        let web = text.range(of: "www.example.com")
        XCTAssertNotNil(row.message.attribute(.link, at: web.location, effectiveRange: nil))
    }

    func testAMessageToUsIsOutlinedAndChipped() {
        var env = ConsoleRowEnvironment()
        env.localCallsign = "K0EPI"
        let row = model(aprsLine(":K0EPI-2  :Hello{1", from: "W0NED"), env: env)
        XCTAssertNotNil(row.outline)
        XCTAssertTrue(row.header.contains { $0.text == "For you" })
    }

    func testTheEnvironmentVersionFollowsWhatChangesARow() {
        var a = ConsoleRowEnvironment()
        let base = a.version
        a.showsRawAPRS = true
        XCTAssertNotEqual(a.version, base)
        var b = ConsoleRowEnvironment()
        b.heardCallsigns = ["W0NED"]
        XCTAssertNotEqual(b.version, base)
        XCTAssertEqual(ConsoleRowEnvironment().version, base)
    }
}
#endif
