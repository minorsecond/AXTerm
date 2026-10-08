//
//  TransferUI.swift
//  AXTerm
//
//  The pieces of the file-transfer interface shared by the Mac, iPad and
//  iPhone: the offer prompt that follows the operator around the app, the
//  actions on a received file, getting picked and dropped files into a form
//  a transfer can read, and sheet sizing that suits each device.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers
import QuickLook
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Menu command routing

/// Carries "Send File…" from the menu bar to the terminal, which owns the
/// picker and the send sheet. The terminal may not be on screen when the
/// command is chosen, so the request waits here until it is.
@MainActor
final class TransferUIRouter: ObservableObject {
    static let shared = TransferUIRouter()

    /// Bumped for each request, so two in a row are two changes.
    @Published private(set) var sendFileRequest = 0
    private(set) var hasPendingSendFileRequest = false

    func requestSendFile() {
        hasPendingSendFileRequest = true
        sendFileRequest += 1
    }

    /// Returns whether a request was waiting, and clears it.
    func consumeSendFileRequest() -> Bool {
        defer { hasPendingSendFileRequest = false }
        return hasPendingSendFileRequest
    }

    /// Whether the terminal is showing its Transfers tab, where the
    /// transfer card would only repeat the row above it (park rehearsal
    /// 2026-10-08).
    @Published var terminalShowsTransfersTab = false

    /// Whether the iPhone and iPad transfer card belongs on screen.
    var showsTransferCard: Bool { !terminalShowsTransfersTab }

    /// Asks the terminal to show its Transfers tab (the transfer chip).
    @Published private(set) var showTransfersRequest = 0
    private(set) var hasPendingShowTransfersRequest = false

    func requestShowTransfers() {
        hasPendingShowTransfersRequest = true
        showTransfersRequest += 1
    }

    func consumeShowTransfersRequest() -> Bool {
        defer { hasPendingShowTransfersRequest = false }
        return hasPendingShowTransfersRequest
    }
}

// MARK: - Sheet sizing

/// A fixed size on the Mac, where sheets are small windows, and the device's
/// own size on iPhone and iPad, where a fixed 560-point sheet ran off the
/// edge of a phone.
struct PlatformSheetFrame: ViewModifier {
    let macWidth: CGFloat
    let macHeight: CGFloat?
    #if os(iOS)
    var detents: Set<PresentationDetent> = [.large]
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(width: macWidth, height: macHeight)
        #else
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .presentationDetents(detents)
        #endif
    }
}

// MARK: - Wording per device

/// Which device's words to use. Kept apart from `#if` so each answer can be
/// tested on one machine.
nonisolated enum TransferDevice: Equatable, Sendable {
    case mac, iPad, iPhone

    @MainActor
    static var current: TransferDevice {
        #if os(macOS)
        return .mac
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #endif
    }
}

nonisolated enum TransferCopy {
    /// The line under "No file transfers". An iPhone cannot drag onto the
    /// terminal and nothing on iOS is clicked.
    static func emptyStateHint(for device: TransferDevice) -> String {
        switch device {
        case .mac: return "Drag a file here or click + to add one."
        case .iPad: return "Drop a file here or tap + to choose one."
        case .iPhone: return "Tap + to choose a file."
        }
    }

    /// Under the empty Transfers list: where a received file goes, so the
    /// operator knows before the first one arrives.
    static func receivedFilesNote(for device: TransferDevice) -> String {
        switch device {
        case .mac:
            return "Files you receive are saved in Downloads › \(ReceivedFileStore.folderName)."
        case .iPad, .iPhone:
            return "Files you receive are saved in the Files app, in AXTerm › \(ReceivedFileStore.folderName)."
        }
    }

    /// Where an accepted file will end up, in the words each device uses.
    static func saveLocation(for device: TransferDevice) -> String {
        switch device {
        case .mac:
            return "It will be saved in Downloads › \(ReceivedFileStore.folderName)."
        case .iPad, .iPhone:
            return "It will be saved in the Files app, in AXTerm › \(ReceivedFileStore.folderName)."
        }
    }

    /// "12 KB by YAPP, about 3 minutes of airtime at the rate of your last
    /// transfer with N0CALL." The airtime clause only appears when a rate has
    /// been measured.
    static func offerSummary(_ request: IncomingTransferRequest) -> String {
        var text = "\(ByteCount.string(request.fileSize)) by \(request.transferProtocol.displayName)"
        if let seconds = request.estimatedAirtimeSeconds {
            text += ", \(TransferAirtimeEstimate.describe(seconds)) of airtime at the rate of your last "
                + "transfer with \(request.sourceCallsign)"
        }
        return text + "."
    }
}

// MARK: - The offer prompt, wherever the operator is

nonisolated enum IncomingTransferPromptQueue {
    /// The offer to show: the one already up while it is still waiting,
    /// otherwise the oldest waiting. An offer that was answered elsewhere
    /// (the Transfers list, a rule, the sender canceling) drops out.
    static func next(pending: [IncomingTransferRequest],
                     showing: IncomingTransferRequest?) -> IncomingTransferRequest? {
        if let showing, pending.contains(where: { $0.id == showing.id }) { return showing }
        return pending.first
    }
}

/// Puts incoming offers in front of the operator from the main window,
/// whichever page it is showing. The allow and deny lists and the size cap
/// were already applied by the coordinator when the offer arrived; only the
/// offers left for a person reach this prompt.
struct IncomingTransferPromptHost: ViewModifier {
    @ObservedObject var coordinator: SessionCoordinator
    let settings: AppSettingsStore

    func body(content: Content) -> some View {
        // Its own background view, so it never competes for one presentation
        // slot with the shell's other sheets (see FirstRunSetupHost).
        content.background {
            Color.clear
                .accessibilityHidden(true)
                .modifier(Presenter(coordinator: coordinator, settings: settings))
        }
    }

    private struct Presenter: ViewModifier {
        @ObservedObject var coordinator: SessionCoordinator
        let settings: AppSettingsStore
        @State private var showing: IncomingTransferRequest?

        func body(content: Content) -> some View {
            content
                .sheet(item: $showing) { request in
                    IncomingTransferSheet(
                        isPresented: Binding(get: { showing != nil }, set: { if !$0 { showing = nil } }),
                        request: request,
                        onAccept: { coordinator.acceptIncomingTransfer(request.id) },
                        onDecline: { coordinator.declineIncomingTransfer(request.id) },
                        onAlwaysAccept: {
                            settings.allowCallsignForFileTransfer(request.sourceCallsign)
                            coordinator.acceptIncomingTransfer(request.id)
                        },
                        onAlwaysDeny: {
                            settings.denyCallsignForFileTransfer(request.sourceCallsign)
                            coordinator.declineIncomingTransfer(request.id)
                        })
                }
                .onAppear { refresh() }
                .onChange(of: coordinator.pendingIncomingTransfers) { _, _ in refresh() }
                .onChange(of: showing) { _, now in
                    // Dismissed without an answer (swiped down): the offer
                    // stays in the Transfers list, and the next one, if any,
                    // comes up.
                    if now == nil { refresh() }
                }
        }

        private func refresh() {
            let next = IncomingTransferPromptQueue.next(
                pending: coordinator.pendingIncomingTransfers, showing: showing)
            guard next?.id != showing?.id else { return }
            showing = next
        }
    }
}

// MARK: - A received file

/// "Saved to AXTerm Transfers" and what can be done with the file from here.
struct ReceivedFileActions: View {
    let path: String
    @State private var previewURL: URL?

    private var url: URL { URL(fileURLWithPath: path) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { caption; Spacer(minLength: 4); buttons }
            VStack(alignment: .leading, spacing: 6) { caption; HStack(spacing: 10) { buttons } }
        }
        .quickLookPreview($previewURL)
    }

    private var caption: some View {
        Label("Saved to \(ReceivedFileStore.folderName)", systemImage: "folder")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(path)
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            previewURL = url
        } label: {
            Label("Quick Look", systemImage: "eye")
        }
        .help("Preview the file")
        #if os(macOS)
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .help("Show the file in \(ReceivedFileStore.folderName) in Finder")
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        .help("Open the file in its default app")
        #else
        ShareLink(item: url) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        #endif
    }
}

// MARK: - Getting files ready to send

/// Copies files the operator picked or dropped into the app's own temporary
/// folder, so the transfer reads a file it will still be allowed to read.
///
/// A file picked on iOS is only readable while its security scope is held,
/// and a dropped file's URL is deleted as soon as the drop callback returns.
/// Copying inside the scope, then letting it go, is what stops the scope
/// from leaking and the drop from reading a file that has gone.
nonisolated enum OutgoingFileStaging {
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AXTerm Outgoing", isDirectory: true)
    }

    enum StagingError: Error, LocalizedError {
        case unreadable(String, String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name, let detail): return "\(name) could not be read: \(detail)"
            }
        }
    }

    /// Copies `url` to a folder of its own under `folder`, keeping its name.
    static func stage(_ url: URL, name: String? = nil, securityScoped: Bool) throws -> URL {
        let scoped = securityScoped && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileName = ReceivedFileStore.sanitize(name ?? url.lastPathComponent)
        let holder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
            let target = holder.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            try? FileManager.default.removeItem(at: holder)
            throw StagingError.unreadable(fileName, error.localizedDescription)
        }
    }

    /// Writes `data` to a folder of its own under `folder` as `name`: a photo
    /// shrunk for sending, staged like any picked file.
    static func stage(data: Data, name: String) throws -> URL {
        let fileName = ReceivedFileStore.sanitize(name)
        let holder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
            let target = holder.appendingPathComponent(fileName)
            try data.write(to: target)
            return target
        } catch {
            try? FileManager.default.removeItem(at: holder)
            throw StagingError.unreadable(fileName, error.localizedDescription)
        }
    }

    /// Removes a staged copy. Files outside the staging folder are left alone.
    static func discard(_ url: URL) {
        let holder = url.deletingLastPathComponent()
        guard holder.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: holder)
    }
}

/// Which dropped items are files to send.
nonisolated enum TransferDropFilter {
    /// A file URL is a file. So is data with a name (Files, Photos, Mail
    /// attachments all name what they drag). Text without a name is someone
    /// dragging words at the terminal, not a file.
    static func isFile(typeIdentifiers: [String], suggestedName: String?) -> Bool {
        let types = typeIdentifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return true }
        let dataTypes = types.filter { $0.conforms(to: .data) || $0.conforms(to: .package) }
        if suggestedName != nil { return !dataTypes.isEmpty }
        return dataTypes.contains { !$0.conforms(to: .text) && !$0.conforms(to: .url) }
    }

    /// The type to ask a provider for: its most specific data type.
    static func preferredType(among typeIdentifiers: [String]) -> String? {
        typeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) || type.conforms(to: .package)
        }
    }
}

/// Loads dropped items as files and stages each one.
@MainActor
enum TransferDropLoader {
    /// Returns whether any item looked like a file. `completion` runs on the
    /// main actor once every item has loaded or failed.
    static func load(_ providers: [NSItemProvider],
                     completion: @escaping @MainActor ([URL], [String]) -> Void) -> Bool {
        let files = providers.filter {
            TransferDropFilter.isFile(typeIdentifiers: $0.registeredTypeIdentifiers, suggestedName: $0.suggestedName)
        }
        guard !files.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var staged: [(Int, URL)] = []
        var failures: [String] = []

        func record(_ index: Int, _ result: Result<URL, Error>) {
            lock.lock()
            switch result {
            case .success(let url): staged.append((index, url))
            case .failure(let error): failures.append(error.localizedDescription)
            }
            lock.unlock()
            group.leave()
        }

        for (index, provider) in files.enumerated() {
            group.enter()
            let name = provider.suggestedName
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                // A Finder drag: the URL itself is readable for this drop.
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    guard let url else {
                        record(index, .failure(error ?? OutgoingFileStaging.StagingError.unreadable(name ?? "The file", "no file URL")))
                        return
                    }
                    record(index, Result { try OutgoingFileStaging.stage(url, securityScoped: true) })
                }
            } else if let type = TransferDropFilter.preferredType(among: provider.registeredTypeIdentifiers) {
                // Files, Photos and other apps on iPad hand over a copy that
                // only exists until this callback returns, so it is copied
                // again before returning.
                _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    guard let url else {
                        record(index, .failure(error ?? OutgoingFileStaging.StagingError.unreadable(name ?? "The file", "nothing to read")))
                        return
                    }
                    let fileName = stagedName(suggested: name, loaded: url, type: type)
                    record(index, Result { try OutgoingFileStaging.stage(url, name: fileName, securityScoped: false) })
                }
            } else {
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let ordered = staged.sorted { $0.0 < $1.0 }.map(\.1)
            MainActor.assumeIsolated { completion(ordered, failures) }
        }
        return true
    }

    /// The provider's name for the item, with an extension if it lacks one,
    /// falling back to the loaded file's own name.
    nonisolated static func stagedName(suggested: String?, loaded: URL, type: String) -> String {
        guard let suggested, !suggested.isEmpty else { return loaded.lastPathComponent }
        if !(suggested as NSString).pathExtension.isEmpty { return suggested }
        if let ext = UTType(type)?.preferredFilenameExtension { return "\(suggested).\(ext)" }
        let loadedExt = loaded.pathExtension
        return loadedExt.isEmpty ? suggested : "\(suggested).\(loadedExt)"
    }
}

/// Photos picked from the library for Send File on the phone and iPad
/// (operator, 2026-10-08). They arrive as bytes with no name, so each gets
/// one from when it was picked, and is staged like a file from Files.
nonisolated enum PickedPhotos {
    /// "Photo-20261008-084210.heic", with "-1", "-2" when several are
    /// picked together. No spaces: the name goes over the air and into the
    /// other station's folder as it is.
    static func name(index: Int, of count: Int, contentType: UTType?, at date: Date,
                     timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let ext = contentType?.preferredFilenameExtension ?? "jpg"
        let number = count > 1 ? "-\(index + 1)" : ""
        return "Photo-\(formatter.string(from: date))\(number).\(ext)"
    }

    /// Stages each photo whose bytes loaded, and names the ones that did not.
    static func stage(_ photos: [(data: Data?, contentType: UTType?)], at date: Date,
                      timeZone: TimeZone = .current) -> (urls: [URL], failed: [String]) {
        var urls: [URL] = []
        var failed: [String] = []
        for (index, photo) in photos.enumerated() {
            let name = name(index: index, of: photos.count, contentType: photo.contentType,
                            at: date, timeZone: timeZone)
            if let data = photo.data, let url = try? OutgoingFileStaging.stage(data: data, name: name) {
                urls.append(url)
            } else {
                failed.append(name)
            }
        }
        return (urls, failed)
    }
}
