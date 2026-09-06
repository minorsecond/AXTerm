//
//  BBSComposeSheet.swift
//  AXTerm
//

import SwiftUI

/// The sysop leaving a message — a reply to a caller, or a bulletin to ALL.
///
/// One sheet on both platforms, because the decisions in it are the same: who
/// it is for, whether that means everybody, and what it says. Only the frame
/// differs — a Mac sheet is sized by its content and an iOS sheet is a screen
/// with a navigation bar, so the buttons live in a toolbar rather than a row.
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
    private var title: String { replyingTo == nil ? "New Message" : "Reply" }
    private var postTitle: String { isBulletin ? "Post Bulletin" : "Leave Message" }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        NavigationStack { touchBody }
        #endif
    }

    // MARK: - Shared parts

    /// A callsign, typed by someone who knows it in capitals.
    ///
    /// Autocapitalisation and autocorrection are both wrong here and both on
    /// by default: a software keyboard will happily turn `K0EPI` into `K0epi`
    /// and `W0ARP` into a word, and the message would then be filed under a
    /// callsign that does not exist. Harmless-looking defaults, and the
    /// mailbox has no way to notice.
    private var recipientField: some View {
        TextField("To", text: $to, prompt: Text("Callsign, or ALL for a bulletin"))
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.characters)
            .keyboardType(.asciiCapable)
            #endif
    }

    /// Said once, where the decision is made: a bulletin is readable by every
    /// caller, and "ALL" does not look different from a callsign.
    @ViewBuilder
    private var bulletinWarning: some View {
        if isBulletin {
            Label("Every caller can read this.", systemImage: "megaphone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func post() {
        onPost(to, subject.isEmpty ? "(none)" : subject, messageBody)
        dismiss()
    }

    private func prefill() {
        if let replyingTo {
            to = replyingTo.from.uppercased()
            subject = replyingTo.subject.lowercased().hasPrefix("re:")
                ? replyingTo.subject
                : "Re: \(replyingTo.subject)"
        }
        bodyFocused = true
    }

    // MARK: - macOS

    #if os(macOS)
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()

            Form {
                recipientField
                    .textFieldStyle(.roundedBorder)
                TextField("Subject", text: $subject)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            bulletinWarning
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

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
                Button(postTitle) { post() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPost)
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
        .onAppear { prefill() }
    }
    #endif

    // MARK: - iOS

    #if os(iOS)
    /// No fixed frame: a sheet sized for a Mac window is wider than a phone,
    /// and SwiftUI simply clips it rather than complaining.
    private var touchBody: some View {
        Form {
            Section {
                recipientField
                TextField("Subject", text: $subject)
            } footer: {
                bulletinWarning
            }

            Section {
                TextEditor(text: $messageBody)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .focused($bodyFocused)
            } header: {
                Text("Message")
            } footer: {
                Text("100 lines or 8 KB, whichever comes first — the same bound a "
                     + "caller gets, because this goes in the same mailbox.")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(postTitle) { post() }
                    .disabled(!canPost)
            }
        }
        .onAppear { prefill() }
    }
    #endif
}
