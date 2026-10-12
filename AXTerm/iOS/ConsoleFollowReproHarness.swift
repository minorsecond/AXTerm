//
//  ConsoleFollowReproHarness.swift
//  AXTerm
//
//  The iPad Session view not following received text (2026-10-12).
//  Launched with `--console-follow-repro` in the simulator. It hosts the
//  real `ConsoleView` as the Session view does (`readsAsConversation`) and
//  feeds it as a long received message arrives: a frame of text from one
//  station every second, each joined onto the same block, with link
//  frames between that the conversation leaves out. Every line names its
//  number, so a screenshot shows whether the newest is in view.
//

#if os(iOS) && DEBUG
import SwiftUI

struct ConsoleFollowReproHarness: View {
    @State private var lines: [ConsoleLine] = [
        ConsoleLine(kind: .system, text: "Connected to K0EPI-7"),
        ConsoleLine(from: "K0EPI-7", to: "K0EPI-3", text: "EPINOD:K0EPI-7} BBS CONNECT INFO NODES ROUTES MH BYE",
                    messageType: .prompt)
    ]
    @State private var clearedAt: Date?
    @State private var count = 0
    @State private var status: InlineSendStatus?
    @State private var compose = ""
    @FocusState private var composing: Bool
    /// A strip above the history, as the Session view's link status.
    @State private var strip = false

    var body: some View {
        // Stacked like the Session view: the compose field below the
        // history, not an inset over it.
        VStack(spacing: 0) {
            if strip {
                Text("K0EPI-4 · AX.25 · Answered by K0EPI-4 · RTT 2.1s · K: 2")
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(.bar)
            }
            ConsoleView(lines: lines, showDaySeparators: false, clearedAt: $clearedAt,
                        trailingSendStatus: status, readsAsConversation: true)
            TextField("Message", text: $compose)
                .textFieldStyle(.roundedBorder)
                .focused($composing)
                .padding()
                .background(.bar)
        }
        .task { await feed() }
    }

    /// The operator sends a line, as from the compose field: waiting,
    /// sending, delivered until the next line arrives.
    private func send(_ text: String) async {
        status = .waiting(text: text)
        try? await Task.sleep(for: .milliseconds(600))
        lines.append(ConsoleLine(from: "K0EPI-3", to: "K0EPI-7", text: text, messageType: .data))
        status = .sending(acked: 0, total: text.count, axdpPeer: nil)
        try? await Task.sleep(for: .milliseconds(800))
        status = .delivered
        try? await Task.sleep(for: .milliseconds(800))
    }

    private func feed() async {
        if ProcessInfo.processInfo.arguments.contains("--switch") { return await switchSessions() }
        if ProcessInfo.processInfo.arguments.contains("--idle") { return await sitIdle() }
        try? await Task.sleep(for: .seconds(1))
        composing = true
        try? await Task.sleep(for: .seconds(1))
        await send("R 1")
        while count < 120 {
            count += 1
            let text = (0..<3).map { "frame \(count) line \($0 + 1): We the People of the United States, in Order" }
                .joined(separator: "\n")
            lines.append(ConsoleLine(from: "K0EPI-7", to: "K0EPI-3", text: text, messageType: .data))
            if status == .delivered { status = nil }
            lines.append(ConsoleLine(from: "K0EPI-3", to: "K0EPI-7", text: "RR(\(count % 8))", messageType: .prompt))
            print("FOLLOW-REPRO frame \(count)")
            if count % 15 == 0 { await send("N") }
            if count == 25 { composing = false }
            if count == 40 { composing = true }
            try? await Task.sleep(for: .seconds(1))
        }
    }
    /// The iPad moving from one session's transcript to another's: a long
    /// one, then the mailbox's three-frame greeting.
    private func switchSessions() async {
        lines = (1...200).map { ConsoleLine(from: "EPINOD", to: "K0EPI-3", text: "node line \($0)",
                                            messageType: .prompt) }
        try? await Task.sleep(for: .seconds(15))
        print("FOLLOW-REPRO switch")
        lines = [
            ConsoleLine(from: "K0EPI-4", to: "K0EPI-3", text: "AXTerm personal mailbox K0EPI-4\nHello Ross.", messageType: .data),
            ConsoleLine(from: "K0EPI-4", to: "K0EPI-3", text: "No new messages for you.", messageType: .data),
            ConsoleLine(from: "K0EPI-4", to: "K0EPI-3", text: "H = help, L = list, R n = read, B = bye\n>", messageType: .data)
        ]
        try? await Task.sleep(for: .seconds(10))
        print("FOLLOW-REPRO back")
        lines = (1...200).map { ConsoleLine(from: "EPINOD", to: "K0EPI-3", text: "node line \($0)",
                                            messageType: .prompt) }
    }

    /// A session sitting idle: the mailbox's greeting, then only the link's
    /// polls, which the conversation leaves out. Sped up from every few
    /// minutes to every second.
    private func sitIdle() async {
        lines = [
            ConsoleLine(from: "K0EPI-4", to: "K0EPI-3", text: "AXTerm personal mailbox K0EPI-4\nHello Ross.", messageType: .data),
            ConsoleLine(from: "K0EPI-4", to: "K0EPI-3", text: "No new messages for you.", messageType: .data),
            ConsoleLine(from: "K0EPI-4", to: "K0EPI-3", text: "H = help, L = list, R n = read, B = bye\n>", messageType: .data)
        ]
        for poll in 1...90 {
            try? await Task.sleep(for: .seconds(1))
            lines.append(ConsoleLine(from: "K0EPI-4", to: "K0EPI-3", text: "RR(3) P", messageType: .prompt))
            lines.append(ConsoleLine(kind: .system, text: "Frame sent successfully"))
            lines.append(ConsoleLine(from: "K0EPI-3", to: "K0EPI-4", text: "RR(0) F", messageType: .prompt))
            print("FOLLOW-REPRO poll \(poll)")
            if poll % 5 == 0 { strip.toggle(); print("FOLLOW-REPRO strip \(strip)") }
        }
    }
}
#endif

