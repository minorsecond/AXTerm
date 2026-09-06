//
//  BBSOtherMailboxesChip.swift
//  AXTerm
//
//  The control that brings other instances' mailboxes into the list, and the
//  headings that keep them apart once they are there.
//

import SwiftUI

/// The switch that brings other mailboxes in.
///
/// A button-style toggle rather than a menu or a settings row: it is a lens on
/// the list it sits above, flipped often, and the operator has to be able to
/// see at a glance whether what they are reading is only this station's.
/// Shaped exactly like the terminal History's "Other devices" chip, because it
/// is the same question asked of a different table.
struct BBSOtherMailboxesChip: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(BBSRemoteMailbox.toggleTitle, systemImage: "laptopcomputer.and.iphone")
                .font(.caption)
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        // Deliberately not `.explain`: the modifier wraps what it decorates in
        // a container of its own, and on iOS that stops a Toggle responding to
        // taps at all. The explanation sits on each remote section's
        // attribution line, beside the rows it actually describes.
        .accessibilityHint(BBSRemoteMailbox.toggleHint)
    }
}

/// A section heading in a list that holds more than one mailbox.
///
/// The attribution is the sentence that makes the section honest — whose
/// mailbox, on which device, at what grid — and it carries the explanation of
/// what "another mailbox" means here: attributed, never merged, read-only.
struct BBSMailboxSectionHeader: View {
    let title: String
    let attribution: String?
    let isRemote: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(title, systemImage: isRemote ? "laptopcomputer.and.iphone" : "tray.full")
                .font(.caption.weight(.semibold))
            if let attribution {
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .explain(BBSRemoteMailbox.attributionExplanation)
            }
        }
        .textCase(nil)
    }
}

/// The line a row carries when it belongs to somebody else's mailbox.
///
/// On the row itself, not only in the section heading: a row is what gets
/// read, screenshotted and remembered, and a message from the home rig's
/// mailbox unmarked in this list reads as mail this mailbox received.
struct BBSOriginLabel: View {
    let label: String?

    var body: some View {
        if let label {
            Label(label, systemImage: "laptopcomputer.and.iphone")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tint)
                .accessibilityLabel("Recorded elsewhere. \(label)")
        }
    }
}
