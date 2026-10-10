#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import AXTerm

/// How long the terminal takes to scroll, a wheel notch at a time.
///
/// The console stuttered on scroll while the Packets table, which reuses its
/// cells, did not (2026-10-10). This hosts the real `ConsoleView` over a
/// channel's worth of decoded APRS lines and times each step, so a change can
/// be measured instead of eyeballed. Opt in with
/// `TEST_RUNNER_AXTERM_SCROLL_BENCH=1`; it prints its numbers and asserts
/// nothing, because timings depend on the machine.
@MainActor
final class ConsoleScrollBenchmark: XCTestCase {

    func testScrollingUpThroughTheConsole() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AXTERM_SCROLL_BENCH"] == "1",
                          "Set TEST_RUNNER_AXTERM_SCROLL_BENCH=1 to run")

        let lines = Self.channel(count: 1000)
        let heard = Set(lines.compactMap { $0.from?.split(separator: "-").first.map(String.init) })
        let view = ConsoleView(
            lines: lines, showDaySeparators: true, clearedAt: .constant(nil),
            localCallsign: "K0EPI", ownCallsigns: ["K0EPI-2", "K0EPI-3"],
            onIdentity: { _ in }, onFileName: { _ in },
            heardCallsigns: heard,
            observer: GreatCircle.Point(latitude: 39.6, longitude: -104.9))
            .frame(width: 1200, height: 700)

        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1200, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        settle(1.0)

        guard let scroll = Self.firstScrollView(in: host), let document = scroll.documentView else {
            return XCTFail("no scroll view")
        }
        let clip = scroll.contentView
        let notch: CGFloat = 40
        let steps = Int(ProcessInfo.processInfo.environment["AXTERM_SCROLL_STEPS"] ?? "") ?? 2000

        var y = clip.bounds.origin.y
        var previous = y
        var stuck = 0
        var times: [Double] = []
        for _ in 0..<steps {
            y += document.isFlipped ? -notch : notch
            let start = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            RunLoop.main.run(until: Date())
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let elapsed = (CACurrentMediaTime() - start) * 1000
            // At the top the clip view stops moving; those steps cost nothing
            // and would only flatter the numbers.
            let atTop = document.isFlipped ? clip.bounds.minY <= document.bounds.minY
                                           : clip.bounds.maxY >= document.bounds.maxY
            if atTop || abs(clip.bounds.origin.y - previous) < 0.5 {
                stuck += 1
                if stuck >= 3 { break }
                continue
            }
            stuck = 0
            previous = clip.bounds.origin.y
            times.append(elapsed)
            y = clip.bounds.origin.y
        }
        guard !times.isEmpty else { return XCTFail("the console never scrolled") }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        let over16 = times.filter { $0 > 16.7 }.count
        let report = String(format: "SCROLLBENCH steps=%d median=%.2fms p95=%.2fms max=%.2fms over16ms=%d total=%.0fms document=%.0fpt\n",
                            times.count, median, p95, sorted.last ?? 0, over16, times.reduce(0, +),
                            document.bounds.height)
        print(report)
        // The test host's stdout does not reach xcodebuild's log, so the
        // numbers also go to a file in its temporary directory.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("console-scroll-bench.txt")
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView,
           (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height * 2 {
            return scroll
        }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    /// A morning on 144.390: mobiles, digis, weather, telemetry, messages,
    /// repeated beacons heard direct and off digis, our own beacon coming back.
    static func channel(count: Int) -> [ConsoleLine] {
        let stations = ["N0AMY-6", "KB7OKL-1", "WA0DE-9", "W0NED", "KE0HXD-7", "AF0AS-9",
                        "SIMLA", "W8XAL-5", "K5RHD-10", "QUAIL", "NCFPD", "W0OOD-2"]
        let paths: [[String]] = [["WIDE1-1", "WIDE2-1"], ["WA6IFI-12*", "WIDE2-1"],
                                 ["W0NED*", "WIDE1*", "WIDE2-1"], ["WA6IFI-12*", "W0NED*", "WIDE2*"]]
        let infos = [
            "!3953.70N/10505.14W>146.520MHz WWW.TONYTYLER.COM",
            "!3923.61N/10440.49W#PHG3830 W2,COn NE Elbert digi www.ARESDEC.org",
            "=3908.02N/10449.11W_090/005g010t062r000p000P000h40b10180 AmbientCWOP.com",
            "T#178,137,140,41,0,0,00010011",
            ":K0EPI-2  :Are you on the net tonight?{12",
            ">ARES R1D5 Weekly Net Thur 20:00 147.105 plus 107.2",
            "!3933.29N/10439.63W-Hi K0EPI-3 heard you via W0NED 73",
            "@101240z3950.70N/10505.14W&PHG8230 Digi/iGate in Arvada DM79",
        ]
        let t0 = Date(timeIntervalSince1970: 1_791_600_000)
        return (0..<count).map { i in
            let from = i % 37 == 0 ? "K0EPI-3" : stations[i % stations.count]
            let info = infos[(i / 3) % infos.count]
            return ConsoleLine.packet(from: from, to: "APRS", text: info,
                                      timestamp: t0.addingTimeInterval(Double(i) * 7),
                                      via: paths[i % paths.count],
                                      radioID: .primary, aprsInfo: Data(info.utf8))
        }
    }
}
#endif
