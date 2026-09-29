//
//  ConsoleHangReproHarness.swift
//  AXTerm
//
//  Isolated, self-terminating reproduction of the ConsoleView layout loop that
//  beach-balled the app on 2026-08-29. Launched with `--console-hang-repro`.
//
//  It hosts the REAL `ConsoleView` — not a copy — so whatever fixes the hang
//  here fixes it in the product, and recreates the conditions the hang needed:
//
//    1. An AppKit `NSPopover` with `.applicationDefined` behaviour hosting a
//       SwiftUI form, presented over the console — the routing/protocol popover.
//       Two SwiftUI hosting views then share one run loop's update pass.
//    2. Content sized near the viewport edge, so the bottom sentinel sits at its
//       visibility boundary — the state from which the smallest layout change
//       flips its onAppear/onDisappear.
//    3. A live line feed (a new ConsoleLine every ~0.3 s) whose scroll-to-bottom
//       repeatedly nudges the sentinel across that boundary — the rig's packets.
//
//  The hang's leaf frame was that sentinel's `.onDisappear` setting
//  `isUserNearBottom` synchronously inside the update pass; because the flag
//  drove layout (the Jump-to-Bottom button was inserted with `if` and the whole
//  ZStack animated on the flag), the write re-hid the sentinel and
//  `propagate_dirty` recursed into an 11k-frame, 100% main-thread stack. The fix
//  makes the flag render-only, so it can no longer perturb layout.
//
//  Safety: a DETACHED (off-main) watchdog force-exits after a fixed wall-clock
//  budget, so even a fully wedged main thread cannot keep the process — or a
//  beach-balled window — alive. A detached heartbeat prints once a second.
//  CPU is measured externally (a wedged main thread cannot measure itself).
//

#if os(macOS)
import SwiftUI
import AppKit

private final class ReproPopoverManager {
    private var popover: NSPopover?
    func open(anchor: NSView) {
        guard popover == nil else { return }
        let controller = NSHostingController(rootView: ReproPopoverForm())
        let pop = NSPopover()
        pop.contentViewController = controller
        pop.behavior = .applicationDefined
        pop.animates = true
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover = pop
    }
}

/// Same shape as the routing popover: pickers and a text field in a sized frame.
private struct ReproPopoverForm: View {
    @State private var mode = 0
    @State private var hop = "Auto"
    @State private var digis = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Protocol").font(.headline)
            Picker("", selection: $mode) {
                Text("AX.25 Direct").tag(0)
                Text("AX.25 via Digi").tag(1)
                Text("NET/ROM").tag(2)
            }
            .pickerStyle(.radioGroup)
            HStack {
                Text("Next hop")
                Picker("", selection: $hop) {
                    Text("Auto").tag("Auto")
                    Text("N0BN-8").tag("N0BN-8")
                }.frame(width: 120)
            }
            TextField("Add digis", text: $digis).frame(width: 240)
        }
        .padding()
        .frame(width: 360)
    }
}

private struct ReproAnchorView: NSViewRepresentable {
    let onAnchor: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onAnchor(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ConsoleHangReproHarness: View {
    @State private var clearedAt: Date?
    @State private var lines: [ConsoleLine]
    @State private var anchor: NSView?
    @State private var popover = ReproPopoverManager()

    /// Window height and starting line count are chosen so the initial content
    /// ends just about at the viewport bottom — the sentinel's boundary.
    private static let windowHeight: CGFloat = 360
    private static let startingLines = 22
    private static let budgetSeconds: TimeInterval = 10

    init() {
        var ls: [ConsoleLine] = []
        for i in 0..<Self.startingLines {
            ls.append(ConsoleLine(kind: .packet, from: "K0RPO-\(i % 9)", to: "NODES",
                                  text: "console hang repro line \(i)"))
        }
        _lines = State(initialValue: ls)
    }

    var body: some View {
        ConsoleView(lines: lines, showDaySeparators: false, clearedAt: $clearedAt)
            .frame(width: 760, height: Self.windowHeight)
            .background(ReproAnchorView { anchor = $0 })
            .onAppear { startDriver() }
    }

    private func startDriver() {
        FileHandle.standardError.write(Data("REPRO: up, budget \(Self.budgetSeconds)s\n".utf8))
        Thread.detachNewThread {
            let start = Date()
            while Date().timeIntervalSince(start) < Self.budgetSeconds {
                Thread.sleep(forTimeInterval: 1)
                FileHandle.standardError.write(
                    Data("REPRO: heartbeat \(Int(Date().timeIntervalSince(start)))s\n".utf8))
            }
            FileHandle.standardError.write(Data("REPRO: watchdog force-exit\n".utf8))
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let anchor { popover.open(anchor: anchor) }
            feedLine()
        }
    }

    /// A BOUNDED burst then stop — the shape of a connect ladder dumping its
    /// reasons/attempts (a few dozen lines over a second or two) and then going
    /// quiet. Each append scrolls to bottom, flipping the bottom sentinel across
    /// its boundary; the question the measurement answers is whether CPU *stays*
    /// pegged after the burst ends (a self-sustaining sentinel storm) or settles.
    /// Runs on the main queue, so if the main thread wedges these stop.
    private func feedLine(remaining: Int = 30) {
        guard remaining > 0 else {
            FileHandle.standardError.write(Data("REPRO: burst done, measuring settle\n".utf8))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            lines.append(ConsoleLine(kind: .packet, from: "K0RPO-\(lines.count % 9)",
                                     to: "NODES", text: "live feed line \(lines.count)"))
            feedLine(remaining: remaining - 1)
        }
    }
}
#endif
