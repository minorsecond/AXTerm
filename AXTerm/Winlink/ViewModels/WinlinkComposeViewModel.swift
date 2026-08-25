import Foundation
import Combine

/// Compose-window model: field editing, address validation, the 120 kB
/// Winlink size budget, and draft/queue persistence.
@MainActor
final class WinlinkComposeViewModel: ObservableObject {

    /// Winlink's practical per-message limit (body + attachments,
    /// uncompressed).
    static let messageSizeBudget = 120 * 1024

    struct AttachmentItem: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var data: Data
        /// Set when `data` is a zip of the file the user attached — kept so
        /// the compression can be undone in place and the saving shown.
        var original: (name: String, data: Data)?

        var isCompressed: Bool { original != nil }

        static func == (lhs: AttachmentItem, rhs: AttachmentItem) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.data == rhs.data
                && lhs.original?.name == rhs.original?.name
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

    private let store: WinlinkStore
    private let myCallsign: String
    /// Non-nil while editing an existing draft row.
    private(set) var draftMID: String?

    init(store: WinlinkStore, myCallsign: String, prefill: WinlinkB2Message? = nil, existingDraftMID: String? = nil) {
        self.store = store
        self.myCallsign = myCallsign
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
    func buildMessage() -> WinlinkB2Message? {
        validationError = nil

        let (to, invalidTo) = Self.parseAddressList(toText)
        let (cc, invalidCc) = Self.parseAddressList(ccText)

        guard invalidTo.isEmpty, invalidCc.isEmpty else {
            validationError = "Invalid address: \((invalidTo + invalidCc).joined(separator: ", "))"
            return nil
        }
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
        guard let message = buildMessage() else { return nil }
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

    /// Saves and queues the message for the next exchange. Returns the MID.
    @discardableResult
    func queueForSending() -> String? {
        guard let mid = saveDraft() else { return nil }
        do {
            try store.queueDraft(mid: mid)
            return mid
        } catch {
            validationError = String(describing: error)
            return nil
        }
    }

    // MARK: - Attachments

    /// Attaches a file, zipping it first when that meaningfully shrinks
    /// what will cross the air. LZHUF — the only compression B2F puts on
    /// the wire — has a 2 KB window; deflate's 32 KB routinely halves a
    /// large text attachment that LZHUF barely dents. Media, archives,
    /// tiny files, and form XML pass through untouched, and the chip in
    /// the compose window shows the saving with an undo.
    func addAttachment(name: String, data: Data) {
        if let zipped = AttachmentCompressor.zipped(name: name, data: data) {
            attachments.append(AttachmentItem(
                name: zipped.name, data: zipped.data, original: (name: name, data: data)))
        } else {
            attachments.append(AttachmentItem(name: name, data: data))
        }
    }

    /// Reverts a zipped attachment to the exact file the user picked.
    func revertAttachmentCompression(id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }),
              let original = attachments[index].original else { return }
        attachments[index] = AttachmentItem(name: original.name, data: original.data)
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }
}
