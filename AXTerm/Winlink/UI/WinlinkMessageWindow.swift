import SwiftUI

/// One received message in its own window.
///
/// The reading pane is as wide as the split allows, which is not wide
/// enough for the products this app now renders natively: a seven-day
/// tabular forecast is eight columns, and a station list is wider still.
/// Rather than compromise the three-pane layout for the widest thing it
/// might ever hold, a message can be lifted out into a window sized for
/// its content.
///
/// Like the compose window, this owns its own mailbox view model keyed
/// off the store — a window that outlives the mail tab cannot borrow its
/// state.
struct WinlinkMessageWindow: View {

    let store: WinlinkStore
    let mid: String
    var myCallsign: String
    /// Called after a reply/forward draft is persisted, so the mail tab
    /// can refresh its counts.
    var onDraftSaved: () -> Void

    @Environment(\.openWindow) private var openWindow
    @StateObject private var viewModel: WinlinkMailboxViewModel

    init(store: WinlinkStore,
         mid: String,
         myCallsign: String,
         onDraftSaved: @escaping () -> Void) {
        self.store = store
        self.mid = mid
        self.myCallsign = myCallsign
        self.onDraftSaved = onDraftSaved
        let callsign = myCallsign
        _viewModel = StateObject(wrappedValue: WinlinkMailboxViewModel(
            store: store, myCallsign: { callsign }))
    }

    /// Reply and forward go through the same persisted-draft path as the
    /// mail tab, so nothing is composed in mid-air and drafts survive a
    /// restart.
    private func openCompose(with draft: WinlinkB2Message) {
        do {
            try store.saveDraft(draft)
            onDraftSaved()
            openWindow(id: "winlinkCompose", value: draft.mid)
        } catch {
            // Nothing to recover here: the draft never existed. The mail
            // tab remains the reliable path.
            NSLog("Winlink: could not save draft from message window: \(error)")
        }
    }

    /// The station's own town, so a state forecast opens on the right city.
    var preferredLocality: String?

    private var stored: WinlinkStoredMessage? {
        try? store.message(mid: mid)
    }

    var body: some View {
        Group {
            if let stored {
                WinlinkMessageDetail(
                                        stored: stored,
                    onReply: { replyAll in
                        openCompose(with: viewModel.replyDraft(to: stored, replyAll: replyAll))
                    },
                    onForward: { openCompose(with: viewModel.forwardDraft(of: stored)) },
                    preferredLocality: preferredLocality)
            } else {
                // A message can be deleted while its window is open.
                VStack(spacing: 6) {
                    Image(systemName: "envelope.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("This message is no longer in the mailbox")
                        .foregroundStyle(.secondary)
                    Text(mid)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .navigationTitle(stored?.message.subject.isEmpty == false
                         ? stored!.message.subject
                         : "Winlink Message")
    }
}
