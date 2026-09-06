//
//  BBSCallersPane.swift
//  AXTerm
//

import SwiftUI

/// Who called, and what they did.
///
/// The operator is asleep for most of what the mailbox does, so this is the
/// view that actually answers "what happened overnight". A caller who reads a
/// bulletin and leaves nothing behind is invisible in the message list and
/// perfectly visible here.
struct BBSCallersPane: View {
    @ObservedObject var service: BBSService
    let now: Date
    /// Opens a caller's identity page. Nil where there is nowhere to go —
    /// the Mac window carries the callers pane without a profile route.
    var onOpenProfile: ((String) -> Void)?
    /// Other instances' mailboxes. Nil where the operator has not switched
    /// mailbox sharing on, or the database could not be opened — and then
    /// this pane behaves exactly as it did before there was such a thing.
    var remoteMailbox: BBSMailboxReplicationStore?

    /// Off, and remembered. An operator who wants every station's callers
    /// wants them every time; one who does not should never meet a row from
    /// another station by surprise while reading their own log.
    @AppStorage("bbs.showsOtherMailboxes") private var showsOtherMailboxes = false
    @State private var remoteCalls: [BBSCallPayload] = []

    private var sections: [BBSUnifiedListing.Section<BBSUnifiedListing.CallRow>] {
        BBSUnifiedListing.callSections(local: service.calls, remote: remoteCalls,
                                       showsOtherInstances: showsOtherMailboxes)
    }

    private var showsChip: Bool {
        BBSRemoteMailbox.showsToggle(hasStore: remoteMailbox != nil,
                                     remoteCount: remoteCalls.count,
                                     isOn: showsOtherMailboxes)
    }

    var body: some View {
        content
            .task { reloadRemote() }
            .onChange(of: showsOtherMailboxes) { _, _ in reloadRemote() }
    }

    /// The log is empty only when *this* station has taken no calls and there
    /// is nothing from anywhere else to show — otherwise the other mailboxes'
    /// calls are the answer to "what happened overnight".
    @ViewBuilder
    private var content: some View {
        if service.calls.isEmpty && sections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "phone.badge.waveform")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("Nobody has called yet").foregroundStyle(.secondary)
                Text("Calls are logged whenever the mailbox is on air, "
                     + "including ones that left nothing behind.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if showsChip {
                    HStack {
                        BBSOtherMailboxesChip(isOn: $showsOtherMailboxes)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    Divider()
                }

                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.rows) { callRow in
                                rowView(callRow)
                            }
                        } header: {
                            if let title = section.title {
                                BBSMailboxSectionHeader(title: title,
                                                        attribution: section.attribution,
                                                        isRemote: section.isRemote)
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.plain)
                #else
                .listStyle(.inset)
                #endif

                if showsChip {
                    Text(BBSUnifiedListing.countLine(local: service.calls.count,
                                                     remote: remoteCalls.count,
                                                     noun: "call"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    /// One row, tappable to a profile where the shell offers one.
    ///
    /// A remote row opens the same profile: a callsign is the same operator
    /// whichever of your stations heard them.
    @ViewBuilder
    private func rowView(_ callRow: BBSUnifiedListing.CallRow) -> some View {
        #if os(iOS)
        if let onOpenProfile {
            Button {
                onOpenProfile(callRow.call.callsign)
            } label: {
                row(callRow.call, originLabel: callRow.origin.label)
            }
            .buttonStyle(.plain)
        } else {
            row(callRow.call, originLabel: callRow.origin.label)
        }
        #else
        row(callRow.call, originLabel: callRow.origin.label)
        #endif
    }

    /// Read whenever there is a store, not only while the chip is on: the
    /// chip appears once something has arrived, so loading only when switched
    /// on could never discover there was anything to show.
    private func reloadRemote() {
        guard BBSRemoteMailbox.shouldLoadRemote(hasStore: remoteMailbox != nil) else {
            remoteCalls = []
            return
        }
        remoteCalls = (try? remoteMailbox?.remoteCalls(limit: 500)) ?? []
    }

    private func row(_ call: BBSCall, originLabel: String? = nil) -> some View {
        let model = BBSCallRowModel.make(call, now: now)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.isLive ? "dot.radiowaves.left.and.right" : "phone.down")
                .font(.caption)
                .foregroundStyle(model.isLive ? Color.green : .secondary)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                BBSOriginLabel(label: originLabel)
                HStack(spacing: 6) {
                    Text(model.callsign)
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.medium)
                    Text(call.connectedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(model.duration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(model.summary.enumerated()), id: \.offset) { _, action in
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(model.didNothing ? .tertiary : .secondary)
                }

                // Worth distinguishing: a caller who said B got what they came
                // for, and one whose link dropped may not have.
                if model.showsLinkDropped {
                    Label("link dropped", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .explain("The session ended without the caller saying B, so their "
                                 + "software may have been mid-command. Whatever they had "
                                 + "already stored is stored.",
                                 showsIndicator: false)
                }
            }
        }
        .padding(.vertical, 3)
    }

}
