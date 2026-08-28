//
//  BBSComposeSheet.swift
//  AXTerm
//

import SwiftUI

// The mailbox UI is macOS-only, like the window layout it lives in. The shell,
// the store and the service are platform-neutral, so an iOS view can be added
// later without touching anything below this layer.
#if os(macOS)

/// The sysop leaving a message — a reply to a caller, or a bulletin to ALL.
struct BBSComposeSheet: View {
    let sysop: String
    let replyingTo: BBSMessage?
    let onPost: (_ to: String, _ subject: String, _ body: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var to: String = ""
    @State private var subject: String = ""
    @State private var messageBody: String = ""
    @FocusState private var bodyFocused: Bool

    private var isBulletin: Bool {
        BBSMessage.baseCall(to) == BBSMessage.allCall
    }
    private var canPost: Bool {
        !to.trimmingCharacters(in: .whitespaces).isEmpty
            && !messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(replyingTo == nil ? "New Message" : "Reply").font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()

            Form {
                TextField("To", text: $to, prompt: Text("Callsign, or ALL for a bulletin"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                TextField("Subject", text: $subject)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            // Said once, where the decision is made: a bulletin is readable by
            // every caller, and "ALL" does not look different from a callsign.
            if isBulletin {
                Label("Every caller can read this.", systemImage: "megaphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            TextEditor(text: $messageBody)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .padding(.horizontal, 12)
                .focused($bodyFocused)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isBulletin ? "Post Bulletin" : "Leave Message") {
                    onPost(to, subject.isEmpty ? "(none)" : subject, messageBody)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canPost)
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
        .onAppear {
            if let replyingTo {
                to = replyingTo.from.uppercased()
                subject = replyingTo.subject.lowercased().hasPrefix("re:")
                    ? replyingTo.subject
                    : "Re: \(replyingTo.subject)"
            }
            bodyFocused = true
        }
    }
}
#endif
