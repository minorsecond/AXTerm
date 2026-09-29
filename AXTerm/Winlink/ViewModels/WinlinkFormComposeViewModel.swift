import Foundation
import Combine

/// Drives one form-filling session: auto-fills, edits, validation, and
/// queueing the rendered message into the Outbox.
@MainActor
final class WinlinkFormComposeViewModel: ObservableObject {

    let template: WinlinkFormTemplate
    @Published var values: [String: String]
    @Published private(set) var validationError: String?

    private let context: WinlinkFormContext
    private let store: WinlinkStore

    init(template: WinlinkFormTemplate, context: WinlinkFormContext, store: WinlinkStore) {
        self.template = template
        self.context = context
        self.store = store
        self.values = WinlinkFormEngine.autoFilledValues(for: template, context: context)
    }

    var visibleFields: [WinlinkFormField] {
        template.fields.filter { !$0.hidden }
    }

    /// Ordered visible sections.
    var sections: [(name: String, fields: [WinlinkFormField])] {
        var order = [String]()
        var grouped = [String: [WinlinkFormField]]()
        for field in visibleFields {
            let section = field.section.isEmpty ? "Details" : field.section
            if grouped[section] == nil { order.append(section) }
            grouped[section, default: []].append(field)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    func binding(for fieldID: String) -> String {
        values[fieldID] ?? ""
    }

    /// Renders and queues the form message. Returns the MID on success.
    @discardableResult
    func queue() -> String? {
        validationError = nil

        for field in template.fields where field.required {
            if (values[field.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                validationError = "“\(field.label)” is required."
                return nil
            }
        }
        guard !context.callsign.isEmpty, context.callsign != "NOCALL" else {
            validationError = "Set your callsign in Settings before sending forms."
            return nil
        }

        let rendered = WinlinkFormEngine.render(template: template, values: values, context: context)

        let (to, invalidTo) = WinlinkComposeViewModel.parseAddressList(rendered.to)
        let (cc, invalidCc) = WinlinkComposeViewModel.parseAddressList(rendered.cc)
        guard invalidTo.isEmpty, invalidCc.isEmpty else {
            validationError = "Invalid address: \((invalidTo + invalidCc).joined(separator: ", "))"
            return nil
        }
        guard !to.isEmpty else {
            validationError = "The form needs a To address."
            return nil
        }
        guard let bodyData = rendered.body.data(using: .isoLatin1) else {
            validationError = "The form contains characters outside ISO-8859-1."
            return nil
        }

        let message = WinlinkB2Message(
            mid: WinlinkB2Message.generateMID(callsign: context.callsign),
            date: context.now,
            type: .privateMessage,
            from: context.callsign,
            to: to,
            cc: cc,
            subject: String(rendered.subject.prefix(WinlinkB2Message.maxSubjectLength)),
            mbo: context.callsign,
            body: bodyData,
            attachments: rendered.attachments)

        do {
            try store.saveDraft(message)
            try store.queueDraft(mid: message.mid)
            return message.mid
        } catch {
            validationError = String(describing: error)
            return nil
        }
    }
}
