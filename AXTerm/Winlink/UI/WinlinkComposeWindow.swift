import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Compose window content. Always edits a persisted draft row (created
/// by the mail pane before the window opens), so drafts survive
/// restarts and reopening.
///
/// A window of its own on the Mac and a sheet on iPhone and iPad. The fields,
/// body and attachments are the same view on both; what differs is where the
/// actions go. A Mac window has room for a footer of labeled buttons. A phone
/// is 393 points wide, and the same footer wrapped every label onto two
/// lines, so on iOS the actions move to where iOS puts them: Save Draft and
/// Queue in the navigation bar, Attach and Position as icons in the bottom
/// toolbar beside a compact size gauge.
struct WinlinkComposeWindow: View {

    /// Owned by the view, not observed: built once from the draft row and
    /// kept across re-renders. As an `@ObservedObject` made in `init`, every
    /// redraw of the window's parent built a fresh model from the stored
    /// draft, dropping whatever had been typed since the last save, and a
    /// photo still being shrunk landed in a model nobody was showing.
    @StateObject private var viewModel: WinlinkComposeViewModel
    @Environment(\.dismiss) private var dismiss
    var onChanged: () -> Void
    var locationService: StationLocationService?
    private let contactStore: ContactStore?
    /// Files to attach as the window opens: something another app handed to
    /// AXTerm. Added through the same planner as a picked file, so a big
    /// photo arrives shrunk with Send Original available.
    private let initialFiles: [ComposeIncomingFile]
    @State private var isFetchingPosition = false
    @State private var isPickingFile = false
    @State private var isPickingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isTakingPhoto = false
    @State private var isDropTargeted = false
    @FocusState private var focusedAddressField: AddressField?

    enum AddressField { case to, cc }

    init(store: WinlinkStore, myCallsign: String, draftMID: String,
         locationService: StationLocationService? = nil,
         contactStore: ContactStore? = nil,
         initialFiles: [ComposeIncomingFile] = [],
         onChanged: @escaping () -> Void) {
        self.locationService = locationService
        self.contactStore = contactStore
        self.initialFiles = initialFiles
        _viewModel = StateObject(wrappedValue: {
            let stored = try? store.message(mid: draftMID)
            return WinlinkComposeViewModel(
                store: store,
                myCallsign: myCallsign,
                prefill: stored?.message,
                existingDraftMID: draftMID)
        }())
        self.onChanged = onChanged
    }

    /// A byte count short enough to sit on one line.
    ///
    /// `ByteCountFormatter` spells zero as "Zero KB" and pads small values,
    /// which is fine in a table column and wrong in a status footer where the
    /// number is next to a progress bar.
    nonisolated static func compactSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if bytes <= 0 { return "0 KB" }
        if kb < 1 { return "<1 KB" }
        if kb < 100 { return String(format: "%.1f KB", kb) }
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        return String(format: "%.1f MB", kb / 1024)
    }

    /// A field with its name beside it on iOS, and unchanged on macOS where
    /// the field already draws its own title.
    @ViewBuilder
    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        #if os(iOS)
        LabeledContent(title, content: content)
        #else
        content()
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            fields
            Divider()
            messageBody
            attachmentStrip
            #if os(macOS)
            Divider()
            macFooter
            #else
            if let error = viewModel.validationError {
                Divider()
                validationLabel(error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 440)
        #else
        .toolbar { iosToolbar }
        #endif
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.item], isTargeted: $isDropTargeted, perform: acceptDrop)
        .task {
            guard !initialFiles.isEmpty, !viewModel.hasTakenInitialFiles else { return }
            viewModel.hasTakenInitialFiles = true
            await viewModel.addAttachments(initialFiles)
            // Written straight away, so a file that came from another app is
            // in Drafts even if the window is closed before anything is typed.
            if viewModel.saveDraftContents() { onChanged() }
        }
        .fileImporter(isPresented: $isPickingFile,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true,
                      onCompletion: addPickedFiles)
        .photosPicker(isPresented: $isPickingPhotos, selection: $photoSelection,
                      maxSelectionCount: 10, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task { await addPhotos(items) }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isTakingPhoto) {
            ComposeCameraPicker { data in
                isTakingPhoto = false
                guard let data else { return }
                let name = ComposeAttachmentIntake.photoName(index: 1, contentType: .jpeg)
                Task { await viewModel.addAttachments([ComposeIncomingFile(name: name, data: data)]) }
            }
            .ignoresSafeArea()
        }
        #endif
        .alert("Attachment not added", isPresented: Binding(
            get: { viewModel.attachmentProblem != nil },
            set: { if !$0 { viewModel.attachmentProblem = nil } })) {
            Button("OK") { viewModel.attachmentProblem = nil }
        } message: {
            Text(viewModel.attachmentProblem ?? "")
        }
    }

    // MARK: - Fields and body

    private var fields: some View {
        Form {
            // A `TextField` title is drawn beside the field on macOS and
            // *replaced* by the prompt on iOS, so on a handheld these
            // three rows arrived as unlabeled boxes. `LabeledContent`
            // puts the name back without changing the Mac.
            labelled("To:") {
                TextField("To:", text: $viewModel.toText,
                          prompt: Text("Callsign or email, comma-separated"))
                    .focused($focusedAddressField, equals: .to)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    #endif
            }
            .explain("Recipients: callsigns (W1AW) or internet addresses (name@example.com, sent through the Winlink internet gateway).",
                     showsIndicator: false)
            addressSuggestions(for: .to)

            labelled("Cc:") {
                TextField("Cc:", text: $viewModel.ccText, prompt: Text("Optional"))
                    .focused($focusedAddressField, equals: .cc)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    #endif
            }
            addressSuggestions(for: .cc)
            HStack {
                labelled("Subject:") {
                    TextField("Subject:", text: $viewModel.subject)
                }
                Text("\(viewModel.subjectRemaining)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(viewModel.subjectRemaining < 0 ? .red : .secondary)
                    .help("Winlink subjects are limited to \(WinlinkB2Message.maxSubjectLength) characters.")
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
    }

    private var messageBody: some View {
        TextEditor(text: $viewModel.bodyText)
            .font(.body.monospaced())
            .padding(4)
            .overlay(alignment: .topLeading) {
                // TextEditor has no prompt of its own. Without one an empty
                // body on a phone is a blank rectangle that does not look
                // like somewhere to type.
                if viewModel.bodyText.isEmpty {
                    Text("Message")
                        .font(.body.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Self.placeholderInset.width)
                        .padding(.vertical, Self.placeholderInset.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    /// Where the text view draws its first character, so the placeholder
    /// sits exactly where typing starts.
    private static var placeholderInset: CGSize {
        #if os(macOS)
        CGSize(width: 9, height: 4)
        #else
        CGSize(width: 9, height: 12)
        #endif
    }

    // MARK: - Attachments

    @ViewBuilder
    private var attachmentStrip: some View {
        if !viewModel.attachments.isEmpty || viewModel.preparingCount > 0 {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.attachments) { item in
                        attachmentChip(item)
                    }
                    if viewModel.preparingCount > 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(viewModel.preparingCount == 1
                                 ? "Preparing attachment" : "Preparing \(viewModel.preparingCount) attachments")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    private func attachmentChip(_ item: WinlinkComposeViewModel.AttachmentItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: Self.chipSymbol(for: item))
                .foregroundStyle(item.note != nil ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).font(.caption).lineLimit(1)
                Text(item.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .explain(Self.chipExplanation(for: item))
            }
            Button {
                viewModel.removeAttachment(id: item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            if item.canSendOriginal {
                Button("Send Original") { viewModel.sendOriginal(id: item.id) }
            }
            if item.isImage, !item.isShrunk, viewModel.isOverBudget {
                Button("Shrink to Fit") { Task { await viewModel.shrinkToFit(id: item.id) } }
            }
            Button("Remove", role: .destructive) { viewModel.removeAttachment(id: item.id) }
        }
    }

    nonisolated static func chipSymbol(for item: WinlinkComposeViewModel.AttachmentItem) -> String {
        if item.note != nil { return "exclamationmark.triangle" }
        switch item.change {
        case .zipped: return "doc.zipper"
        case .shrunk, .locationRemoved: return "photo"
        case .none: return item.isImage ? "photo" : "paperclip"
        }
    }

    /// How to reach the chip's menu on this platform; see
    /// `AttachmentActions.secondaryClick`.
    nonisolated static var secondaryAction: String { AttachmentActions.secondaryClick() }

    /// Why the chip says what it says.
    nonisolated static func chipExplanation(for item: WinlinkComposeViewModel.AttachmentItem) -> String {
        if let note = item.note { return note }
        switch item.change {
        case .zipped:
            return "Zipped before sending. LZHUF (the only compression Winlink puts on the wire) "
                + "has a 2 KB window and barely dents a file this size. The recipient opens the zip "
                + "with any tool. \(secondaryAction) the attachment to send the original instead."
        case .shrunk(let width, let height):
            return "Scaled to \(width) \u{00D7} \(height) and saved as JPEG so the message fits "
                + "Winlink's budget and does not tie up the channel for longer than it needs to. "
                + "Its GPS position goes with it only when Keep Photo Location is on in the Attach menu. "
                + "\(secondaryAction) the attachment to send the original instead."
        case .locationRemoved:
            return "The photo's GPS position was removed, since anyone listening can copy the "
                + "message. The picture itself is untouched. \(secondaryAction) the attachment to "
                + "send it with the location, or turn on Keep Photo Location in the Attach menu."
        case .none:
            return "\(item.name) is sent exactly as attached."
        }
    }

    // MARK: - Attach menu

    private var attachMenu: some View {
        Menu {
            Button {
                isPickingFile = true
            } label: {
                Label("Files\u{2026}", systemImage: "folder")
            }
            Button {
                isPickingPhotos = true
            } label: {
                Label("Photos\u{2026}", systemImage: "photo.on.rectangle")
            }
            #if os(iOS)
            if ComposeCameraPicker.isAvailable {
                Button {
                    isTakingPhoto = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
            #endif
            Button {
                Task {
                    let pasted = await ComposeAttachmentIntake.pasteboardContents()
                    if pasted.files.isEmpty && pasted.failures.isEmpty {
                        viewModel.attachmentProblem = "The clipboard has no file or picture to attach."
                    }
                    viewModel.reportUnreadable(pasted.failures)
                    await viewModel.addAttachments(pasted.files)
                }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            Divider()
            Toggle(isOn: $viewModel.keepsPhotoLocation) {
                Label("Keep Photo Location", systemImage: "location")
            }
        } label: {
            #if os(macOS)
            Label("Attach", systemImage: "paperclip")
            #else
            Label("Attach", systemImage: "paperclip")
                .labelStyle(.iconOnly)
            #endif
        }
        .accessibilityLabel("Attach")
        .help("Attach files or photos. Photos too big for the message are shrunk to fit. "
              + "You can also drag files onto this window.")
    }

    // MARK: - Position

    private var positionButton: some View {
        Button {
            insertPosition()
        } label: {
            if isFetchingPosition {
                ProgressView().controlSize(.small)
            } else {
                #if os(macOS)
                Label("Position", systemImage: "location")
                #else
                Label("Insert Position", systemImage: "location")
                    .labelStyle(.iconOnly)
                #endif
            }
        }
        .disabled(isFetchingPosition)
        .accessibilityLabel("Insert Position")
        .help("Insert your position (GPS when available, otherwise your grid square's center) into the message body.")
    }

    private func insertPosition() {
        guard let locationService else { return }
        isFetchingPosition = true
        Task { @MainActor in
            defer { isFetchingPosition = false }
            guard let location = await locationService.currentLocation() else { return }
            let stamp = StationLocationFormat.stamp(location)
            if !viewModel.bodyText.isEmpty, !viewModel.bodyText.hasSuffix("\n") {
                viewModel.bodyText += "\n"
            }
            viewModel.bodyText += stamp + "\n"
        }
    }

    // MARK: - Actions

    private func saveDraft() {
        if viewModel.saveDraft() != nil {
            onChanged()
            dismiss()
        }
    }

    private func queue() {
        if viewModel.queueForSending() != nil {
            recordContactUse()
            onChanged()
            dismiss()
        }
    }

    private func validationLabel(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
    }

    #if os(macOS)
    private var macFooter: some View {
        HStack(spacing: 10) {
            attachMenu
                .fixedSize()
            if locationService != nil {
                positionButton
            }
            sizeGauge(barWidth: 90)
            if let error = viewModel.validationError {
                validationLabel(error)
            }
            Spacer()
            Button("Save Draft", action: saveDraft)
                .help("Keep editing later. Drafts live in the Drafts folder.")
            Button("Queue for Sending", action: queue)
                .keyboardShortcut(.defaultAction)
                .help("Freezes the message and moves it to the Outbox. It is transmitted at the next Connect & Exchange.")
        }
        .padding(12)
    }
    #endif

    #if os(iOS)
    @ToolbarContentBuilder
    private var iosToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Queue", action: queue)
                .accessibilityHint("Moves the message to the Outbox. It is sent at the next Connect and Exchange.")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Save Draft", action: saveDraft)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            attachMenu
            if locationService != nil {
                positionButton
            }
            Spacer()
            sizeGauge(barWidth: 56)
        }
    }
    #endif

    private func sizeGauge(barWidth: CGFloat) -> some View {
        let total = viewModel.totalSizeBytes
        let budget = WinlinkComposeViewModel.messageSizeBudget
        let fraction = min(1.0, Double(total) / Double(budget))
        return HStack(spacing: 6) {
            ProgressView(value: fraction)
                .frame(width: barWidth)
                .tint(viewModel.isOverBudget ? .red : (fraction > 0.75 ? .orange : .accentColor))
            // Formatted by hand rather than by ByteCountFormatter, which
            // renders 0 as "Zero KB" — three words where one number belongs,
            // and enough of them to wrap the footer onto three lines.
            Text("\(Self.compactSize(total)) / \(Self.compactSize(budget))")
                .fixedSize(horizontal: true, vertical: false)
                .font(.caption.monospacedDigit())
                .foregroundStyle(viewModel.isOverBudget ? .red : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Message size")
        .accessibilityValue("\(Self.compactSize(total)) of \(Self.compactSize(budget))")
        .explain(WinlinkCopy.attachmentBudgetTooltip, showsIndicator: false)
    }

    // MARK: - Address suggestions

    /// Contact chips completing the fragment after the last comma.
    @ViewBuilder
    private func addressSuggestions(for field: AddressField) -> some View {
        if let contactStore, focusedAddressField == field {
            let text = field == .to ? viewModel.toText : viewModel.ccText
            let fragment = text.split(separator: ",", omittingEmptySubsequences: false)
                .last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let matches = ((try? contactStore.searchContacts(fragment)) ?? [])
                .filter { $0.preferredAddress != nil }
                .prefix(5)
            if !matches.isEmpty, fragment.count >= 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(matches)) { contact in
                            Button {
                                complete(field: field, with: contact)
                            } label: {
                                HStack(spacing: 4) {
                                    if contact.favorite {
                                        Image(systemName: "star.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.yellow)
                                    }
                                    Text(contact.displayName).font(.caption)
                                    Text(contact.preferredAddress ?? "")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Use \(contact.preferredAddress ?? "") from your contacts")
                        }
                    }
                }
            }
        }
    }

    private func complete(field: AddressField, with contact: WinlinkContactRecord) {
        guard let address = contact.preferredAddress else { return }
        let text = field == .to ? viewModel.toText : viewModel.ccText
        var parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty {
            parts = [address]
        } else {
            parts[parts.count - 1] = address
        }
        let joined = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        if field == .to {
            viewModel.toText = joined
        } else {
            viewModel.ccText = joined
        }
    }

    /// Bumps contact recency for every queued address.
    private func recordContactUse() {
        guard let contactStore else { return }
        let (to, _) = WinlinkComposeViewModel.parseAddressList(viewModel.toText)
        let (cc, _) = WinlinkComposeViewModel.parseAddressList(viewModel.ccText)
        let now = Date()
        for address in to + cc {
            try? contactStore.touchContact(address: address, at: now)
        }
    }

    // MARK: - Getting files in

    /// Reads the files the operator picked.
    ///
    /// A file that cannot be read is reported rather than skipped: silently
    /// attaching three of four selected files sends an incomplete message
    /// over airtime that cannot be recovered.
    private func addPickedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            viewModel.attachmentProblem = error.localizedDescription
        case .success(let urls):
            var files: [ComposeIncomingFile] = []
            var failed: [String] = []
            for url in urls {
                // A file outside the app's container needs explicit access,
                // and that scope is released again inside `read`.
                if let file = ComposeAttachmentIntake.read(url) {
                    files.append(file)
                } else {
                    failed.append(url.lastPathComponent)
                }
            }
            viewModel.reportUnreadable(failed)
            Task { await viewModel.addAttachments(files) }
        }
    }

    /// Photos from the library arrive as their original bytes (HEIC from an
    /// iPhone camera), with no names. The planner shrinks what will not fit.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        var files: [ComposeIncomingFile] = []
        var failed: [String] = []
        let existing = viewModel.attachments.count
        for (offset, item) in items.enumerated() {
            let type = item.supportedContentTypes.first
            let name = ComposeAttachmentIntake.photoName(index: existing + offset + 1, contentType: type)
            if let data = try? await item.loadTransferable(type: Data.self) {
                files.append(ComposeIncomingFile(name: name, data: data))
            } else {
                failed.append(name)
            }
        }
        viewModel.reportUnreadable(failed)
        await viewModel.addAttachments(files)
    }

    /// Accepts files and pictures dropped anywhere on the window. Returns
    /// false, so the drop is refused visibly, when nothing dropped is a file
    /// (dragged text goes to the text view under the pointer instead).
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let usable = providers.filter {
            ComposeAttachmentIntake.route(for: $0.registeredTypeIdentifiers,
                                          hasSuggestedName: $0.suggestedName != nil) != .unsupported
        }
        guard !usable.isEmpty else { return false }
        Task {
            let loaded = await ComposeAttachmentIntake.load(usable)
            viewModel.reportUnreadable(loaded.failures)
            await viewModel.addAttachments(loaded.files)
        }
        return true
    }
}
