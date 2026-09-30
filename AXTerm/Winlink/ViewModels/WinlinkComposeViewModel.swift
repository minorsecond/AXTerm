import Foundation
import Combine

/// Compose-window model: field editing, address validation, the 120 kB
/// Winlink size budget, and draft/queue persistence.
@MainActor
final class WinlinkComposeViewModel: ObservableObject {

    /// Winlink's practical per-message limit (body + attachments,
    /// uncompressed).
    nonisolated static let messageSizeBudget = 120 * 1024

    nonisolated struct AttachmentItem: Identifiable, Hashable, Sendable {
        /// What was done to the file the operator attached before it went
        /// into the message.
        enum Change: Hashable, Sendable {
            case none
            /// Zipped, because deflate beats LZHUF on this file.
            case zipped
            /// A photo scaled down and re-encoded as JPEG to fit the budget.
            case shrunk(pixelWidth: Int, pixelHeight: Int)
            /// A photo with its GPS position taken out, pixels untouched.
            case locationRemoved
        }

        /// Kept through Send Original and Shrink to Fit, so the chip changes
        /// in place rather than being replaced by a new one.
        var id = UUID()
        var name: String
        var data: Data
        /// Set when `data` is not the file the user attached (zipped, shrunk
        /// or with its location removed), kept so the change can be undone
        /// in place and the saving shown.
        var original: (name: String, data: Data)?
        var change: Change
        /// Why a photo that is over the budget was not shrunk. Shown on the
        /// chip so a red gauge comes with a reason.
        var note: String?

        /// An `original` with no `change` given means zipped, which is what
        /// it meant before photos could be shrunk.
        init(name: String, data: Data, original: (name: String, data: Data)? = nil,
             change: Change = .none, note: String? = nil) {
            self.name = name
            self.data = data
            self.original = original
            self.change = original == nil ? .none : (change == .none ? .zipped : change)
            self.note = note
        }

        var isCompressed: Bool { change == .zipped }
        var isShrunk: Bool { if case .shrunk = change { return true } else { return false } }
        /// True when "Send Original" has something to go back to.
        var canSendOriginal: Bool { original != nil }
        var isImage: Bool { ImageShrinker.isImage(named: name) }

        /// The line under the name on the compose chip.
        var summary: String {
            let now = ByteCount.string(Int64(data.count))
            guard let original else { return now }
            let before = ByteCount.string(Int64(original.data.count))
            switch change {
            case .shrunk:
                return "Shrunk to \(now) from \(before)"
            case .locationRemoved:
                return "\(now), location removed"
            case .zipped, .none:
                return before + " \u{2192} " + now
            }
        }

        static func == (lhs: AttachmentItem, rhs: AttachmentItem) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.data == rhs.data
                && lhs.original?.name == rhs.original?.name
                && lhs.change == rhs.change && lhs.note == rhs.note
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(name)
        }
    }

    @Published var toText: String = ""
    @Published var ccText: String = ""
    @Published var subject: String = ""
    @Published var bodyText: String = ""
    @Published var attachments: [AttachmentItem] = []
    @Published private(set) var validationError: String?
    /// Files being read or photos being shrunk. The chip strip shows a
    /// placeholder while this is above zero, so an attach that takes a second
    /// does not look like one that did nothing.
    @Published private(set) var preparingCount = 0
    /// Something the operator picked that could not be attached, with the
    /// reason. Cleared by the alert that shows it.
    @Published var attachmentProblem: String?
    /// Keep a photo's GPS position when it is attached. Remembered across
    /// messages, and off unless the operator turns it on, because a photo
    /// taken at home says where home is to everyone who copies the message.
    @Published var keepsPhotoLocation: Bool {
        didSet { defaults.set(keepsPhotoLocation, forKey: Self.keepsPhotoLocationKey) }
    }

    static let keepsPhotoLocationKey = "winlink.compose.keepsPhotoLocation"

    private let store: WinlinkStore
    private let myCallsign: String
    private let defaults: UserDefaults
    /// Non-nil while editing an existing draft row.
    private(set) var draftMID: String?

    init(store: WinlinkStore, myCallsign: String, prefill: WinlinkB2Message? = nil,
         existingDraftMID: String? = nil, defaults: UserDefaults = AppEnvironment.defaults) {
        self.store = store
        self.myCallsign = myCallsign
        self.defaults = defaults
        self.keepsPhotoLocation = defaults.bool(forKey: Self.keepsPhotoLocationKey)
        self.draftMID = existingDraftMID

        if let prefill {
            toText = prefill.to.joined(separator: ", ")
            ccText = prefill.cc.joined(separator: ", ")
            subject = prefill.subject
            bodyText = String(data: prefill.body, encoding: .isoLatin1) ?? ""
            attachments = prefill.attachments.map { AttachmentItem(name: $0.name, data: $0.data) }
            if existingDraftMID != nil {
                draftMID = prefill.mid
            }
        }
    }

    // MARK: - Derived state

    var totalSizeBytes: Int {
        bodyText.utf8.count + attachments.reduce(0) { $0 + $1.data.count }
    }

    var isOverBudget: Bool { totalSizeBytes > Self.messageSizeBudget }

    var subjectRemaining: Int { WinlinkB2Message.maxSubjectLength - subject.count }

    // MARK: - Address handling

    /// Normalizes one recipient: callsigns pass through uppercased,
    /// internet addresses gain the `SMTP:` prefix Winlink requires.
    static func normalizeAddress(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let upper = trimmed.uppercased()
        if upper.hasPrefix("SMTP:") {
            let rest = String(trimmed.dropFirst(5))
            return rest.contains("@") ? "SMTP:\(rest)" : nil
        }
        if trimmed.contains("@") {
            return "SMTP:\(trimmed)"
        }
        // Callsign with optional SSID or tactical address.
        let callsignPattern = "^[A-Z0-9]{3,7}(-[0-9]{1,2})?$"
        if upper.range(of: callsignPattern, options: .regularExpression) != nil {
            return upper
        }
        return nil
    }

    static func parseAddressList(_ text: String) -> (valid: [String], invalid: [String]) {
        var valid = [String]()
        var invalid = [String]()
        for piece in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let raw = piece.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            if let normalized = normalizeAddress(raw) {
                valid.append(normalized)
            } else {
                invalid.append(raw)
            }
        }
        return (valid, invalid)
    }

    // MARK: - Building and saving

    /// Validates fields and builds the message. Publishes
    /// `validationError` and returns nil when invalid.
    ///
    /// `complete` is false for a draft, which only has to be storable: a
    /// draft is where a message waits while it is still missing things, and
    /// refusing to save one because it had no To address yet lost the work
    /// it existed to keep. Queueing asks for everything.
    func buildMessage(complete: Bool = true) -> WinlinkB2Message? {
        validationError = nil

        let (to, invalidTo) = Self.parseAddressList(toText)
        let (cc, invalidCc) = Self.parseAddressList(ccText)

        guard invalidTo.isEmpty, invalidCc.isEmpty else {
            validationError = "Invalid address: \((invalidTo + invalidCc).joined(separator: ", "))"
            return nil
        }
        if complete {
            guard !to.isEmpty else {
                validationError = "At least one To address is required."
                return nil
            }
            guard subject.count <= WinlinkB2Message.maxSubjectLength else {
                validationError = "Subject exceeds \(WinlinkB2Message.maxSubjectLength) characters."
                return nil
            }
            guard !isOverBudget else {
                validationError = "Message exceeds the \(Self.messageSizeBudget / 1024) kB Winlink limit."
                return nil
            }
        }
        guard !myCallsign.isEmpty, myCallsign != "NOCALL" else {
            validationError = "Set your callsign in Settings before composing mail."
            return nil
        }

        // Winlink bodies are ISO-8859-1 with CRLF endings; normalize both
        // and reject characters that cannot survive the trip.
        let normalizedText = bodyText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        guard let bodyData = normalizedText.data(using: .isoLatin1) else {
            validationError = "The body contains characters outside ISO-8859-1 (Winlink's character set)."
            return nil
        }
        guard subject.data(using: .isoLatin1) != nil else {
            validationError = "The subject contains characters outside ISO-8859-1."
            return nil
        }

        return WinlinkB2Message(
            mid: draftMID ?? WinlinkB2Message.generateMID(callsign: myCallsign),
            date: Date(),
            type: .privateMessage,
            from: myCallsign,
            to: to,
            cc: cc,
            subject: subject,
            mbo: myCallsign,
            body: bodyData,
            attachments: attachments.map { .init(name: $0.name, data: $0.data) })
    }

    /// Saves (or re-saves) the compose state as a draft. Returns the MID.
    @discardableResult
    func saveDraft() -> String? {
        guard let message = buildMessage(complete: false) else { return nil }
        do {
            if draftMID != nil {
                try store.updateDraft(message)
            } else {
                try store.saveDraft(message)
                draftMID = message.mid
            }
            return message.mid
        } catch {
            validationError = String(describing: error)
            return nil
        }
    }

    /// Writes what is in the window to the draft row without checking it,
    /// for keeping attachments that arrived from another app safe before
    /// the operator has addressed anything. Queueing still validates
    /// everything. Returns false when the draft could not be written (a body
    /// Winlink cannot carry, or no draft row yet), which leaves the window
    /// holding the only copy, exactly as before this was called.
    @discardableResult
    func saveDraftContents() -> Bool {
        guard let draftMID, !myCallsign.isEmpty else { return false }
        let body = bodyText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        guard let bodyData = body.data(using: .isoLatin1) else { return false }
        let message = WinlinkB2Message(
            mid: draftMID,
            date: Date(),
            type: .privateMessage,
            from: myCallsign,
            to: Self.parseAddressList(toText).valid,
            cc: Self.parseAddressList(ccText).valid,
            subject: subject,
            mbo: myCallsign,
            body: bodyData,
            attachments: attachments.map { .init(name: $0.name, data: $0.data) })
        return (try? store.updateDraft(message)) != nil
    }

    /// Set once the files a compose window was opened with have been added,
    /// so reappearing (a sheet brought back, a window restored) does not add
    /// them twice.
    var hasTakenInitialFiles = false

    /// Saves and queues the message for the next exchange. Returns the MID.
    @discardableResult
    func queueForSending() -> String? {
        // Everything checked before anything is written, so a message that
        // cannot go is not half-saved on the way to saying so.
        guard buildMessage(complete: true) != nil, let mid = saveDraft() else { return nil }
        do {
            try store.queueDraft(mid: mid)
            return mid
        } catch {
            validationError = String(describing: error)
            return nil
        }
    }

    // MARK: - Attachments

    /// What is left of the budget after the body and every attachment.
    var remainingBudget: Int { Self.messageSizeBudget - totalSizeBytes }

    /// Attaches a file, shrinking or zipping it first when that is worth
    /// doing (see `ComposeAttachmentPlanner`). The chip in the compose window
    /// shows what changed, with an undo.
    ///
    /// Runs on the caller's thread. The compose window uses
    /// `addAttachments(_:)` instead, which does the work off the main actor,
    /// because shrinking a 12-megapixel photo takes long enough to stall
    /// typing.
    func addAttachment(name: String, data: Data) {
        append(ComposeAttachmentPlanner.plan(
            name: name, data: data, remainingBudget: remainingBudget,
            keepsLocation: keepsPhotoLocation))
    }

    /// Attaches several files in order, each planned against the budget the
    /// ones before it left. The heavy part runs off the main actor.
    func addAttachments(_ files: [ComposeIncomingFile]) async {
        guard !files.isEmpty else { return }
        preparingCount += files.count
        for file in files {
            let remaining = remainingBudget
            let keeps = keepsPhotoLocation
            let item = await Task.detached(priority: .userInitiated) {
                ComposeAttachmentPlanner.plan(name: file.name, data: file.data,
                                              remainingBudget: remaining, keepsLocation: keeps)
            }.value
            append(item)
            preparingCount -= 1
        }
    }

    /// Reports files that could not be read, naming each in one alert.
    /// Attaching three of four and saying nothing sends an incomplete message
    /// over airtime that cannot be recovered.
    func reportUnreadable(_ names: [String]) {
        guard !names.isEmpty else { return }
        attachmentProblem = "Could not read: " + names.joined(separator: ", ")
    }

    private func append(_ item: AttachmentItem) {
        var item = item
        item.name = ComposeAttachmentIntake.uniqueName(item.name, existing: attachments.map(\.name))
        attachments.append(item)
    }

    /// Puts back the exact file the operator attached: unzipped, unshrunk,
    /// location and all.
    func sendOriginal(id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }),
              let original = attachments[index].original else { return }
        var restored = AttachmentItem(
            name: ComposeAttachmentIntake.uniqueName(original.name, existing: names(except: index)),
            data: original.data)
        restored.id = id
        attachments[index] = restored
    }

    /// The older name for `sendOriginal(id:)`, from when zipping was the only
    /// change there was to undo.
    func revertAttachmentCompression(id: UUID) {
        sendOriginal(id: id)
    }

    /// Shrinks a photo that is going as the original, against the budget left
    /// by everything else. Offered after the operator chose Send Original and
    /// then found the message would not fit.
    func shrinkToFit(id: UUID) async {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let item = attachments[index]
        let source = item.original ?? (name: item.name, data: item.data)
        let remaining = remainingBudget + item.data.count
        let keeps = keepsPhotoLocation
        preparingCount += 1
        defer { preparingCount -= 1 }
        let planned = await Task.detached(priority: .userInitiated) {
            ComposeAttachmentPlanner.plan(name: source.name, data: source.data,
                                          remainingBudget: remaining, keepsLocation: keeps,
                                          forceShrink: true)
        }.value
        // The operator may have removed it while it was being shrunk.
        guard let current = attachments.firstIndex(where: { $0.id == id }) else { return }
        var replacement = planned
        replacement.id = id
        replacement.name = ComposeAttachmentIntake.uniqueName(planned.name, existing: names(except: current))
        attachments[current] = replacement
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    private func names(except index: Int) -> [String] {
        attachments.enumerated().filter { $0.offset != index }.map(\.element.name)
    }
}

/// Decides what goes into a message when the operator attaches a file.
///
/// Photos are the case that matters. A phone photo is several megabytes and
/// the whole message may be 120 KB, so a photo that would push the message
/// over is shrunk by default, to a size that is kind to the channel, and the
/// operator can still choose Send Original. Other files are zipped when
/// deflate beats LZHUF (see `AttachmentCompressor`).
///
/// Nothing is dropped and nothing is changed without the chip saying so. A
/// photo that cannot be shrunk into the room left goes in as it is, with a
/// note; the budget gauge turns red and Queue refuses. That is better than a
/// message that silently lost a picture.
nonisolated enum ComposeAttachmentPlanner {

    /// The size a shrunk photo aims for when the message has room for more.
    /// About five minutes at 1200 baud, and enough for a 1024-pixel photo a
    /// recipient can actually read.
    static let photoTargetBytes = 48 * 1024

    /// Below this there is no room for a photo worth sending, and shrinking
    /// is not attempted.
    static let minimumPhotoBytes = 6 * 1024

    /// The longest edge a shrunk photo starts from.
    static let photoMaxLongEdge = 1280

    static func plan(name: String, data: Data, remainingBudget: Int, keepsLocation: Bool,
                     forceShrink: Bool = false) -> WinlinkComposeViewModel.AttachmentItem {
        guard !isFormAttachment(name), ImageShrinker.isImage(data) else {
            if let zipped = AttachmentCompressor.zipped(name: name, data: data) {
                return .init(name: zipped.name, data: zipped.data,
                             original: (name: name, data: data), change: .zipped)
            }
            return .init(name: name, data: data)
        }
        if data.count <= remainingBudget && !forceShrink {
            // It fits. Only the location may need to come out.
            guard !keepsLocation, ImageShrinker.containsLocation(data) else {
                return .init(name: name, data: data)
            }
            return shrink(name: name, data: data, budget: remainingBudget, keepsLocation: false)
        }
        let target = min(photoTargetBytes, remainingBudget)
        guard target >= minimumPhotoBytes else {
            return .init(name: name, data: data,
                         note: "There is no room left in this message to shrink it into. "
                             + "Remove something, or send it in a message of its own.")
        }
        return shrink(name: name, data: data, budget: target, keepsLocation: keepsLocation)
    }

    private static func shrink(name: String, data: Data, budget: Int,
                               keepsLocation: Bool) -> WinlinkComposeViewModel.AttachmentItem {
        let options = ImageShrinker.Options(byteBudget: budget, maxLongEdge: photoMaxLongEdge,
                                            keepsLocation: keepsLocation)
        switch ImageShrinker.shrink(data, name: name, options: options) {
        case .success(.shrunk(let shrunk)):
            return .init(name: shrunk.name, data: shrunk.data,
                         original: (name: name, data: data),
                         change: .shrunk(pixelWidth: shrunk.pixelWidth, pixelHeight: shrunk.pixelHeight))
        case .success(.locationRemoved(let stripped)):
            return .init(name: name, data: stripped,
                         original: (name: name, data: data), change: .locationRemoved)
        case .success(.unchanged):
            return .init(name: name, data: data)
        case .failure(.animated):
            return .init(name: name, data: data,
                         note: "Animated images go as they are, since shrinking one keeps only its first frame.")
        case .failure(.cannotMeetBudget(let smallest)):
            return .init(name: name, data: data,
                         note: "It would not go below \(ByteCount.string(smallest)) "
                             + "without getting too small to be useful, so it is attached as it is.")
        case .failure(.notAnImage), .failure(.encodeFailed):
            return .init(name: name, data: data,
                         note: "This image could not be re-encoded, so it is attached as it is.")
        }
    }

    /// Winlink form workflows key on exact attachment names, so a form's
    /// files are never renamed or changed.
    private static func isFormAttachment(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "xml"
    }
}
