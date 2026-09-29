import SwiftUI

/// Two-stage forms flow: pick a template from the catalog, fill it in a
/// native editor, queue it to the Outbox.
struct WinlinkFormsSheet: View {

    let store: WinlinkStore
    let makeContext: () async -> WinlinkFormContext
    var onQueued: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var formVM: WinlinkFormComposeViewModel?
    @State private var isPreparing = false
    @State private var queuedTemplateTitle: String?

    var body: some View {
        VStack(spacing: 0) {
            if let formVM {
                WinlinkFormEditorView(
                    viewModel: formVM,
                    onBack: { self.formVM = nil },
                    onQueue: {
                        if formVM.queue() != nil {
                            queuedTemplateTitle = formVM.template.title
                            onQueued()
                        }
                    })
            } else {
                picker
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .alert("Form queued", isPresented: Binding(
            get: { queuedTemplateTitle != nil },
            set: { if !$0 { queuedTemplateTitle = nil } })) {
            Button("OK") { dismiss() }
        } message: {
            Text("“\(queuedTemplateTitle ?? "")” is in your Outbox. Send it with Connect & Exchange.")
        }
    }

    // MARK: - Template picker

    private var picker: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Winlink Forms")
                    .font(.headline)
                    .help("Standard Winlink templates rendered natively. Recipients running Winlink Express (or any client) see the official form — AXTerm sends the same body and form data attachment.")
                Spacer()
                if isPreparing { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }
            }
            .padding(12)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groupedTemplates, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.category)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 10)], spacing: 10) {
                                ForEach(group.templates) { template in
                                    templateCard(template)
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private var groupedTemplates: [(category: String, templates: [WinlinkFormTemplate])] {
        var order = [String]()
        var grouped = [String: [WinlinkFormTemplate]]()
        for template in WinlinkFormTemplates.all {
            if grouped[template.category] == nil { order.append(template.category) }
            grouped[template.category, default: []].append(template)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private func templateCard(_ template: WinlinkFormTemplate) -> some View {
        Button {
            isPreparing = true
            Task { @MainActor in
                // Resolving the context may take a GPS fix — do it once,
                // when the form opens, so the fields land pre-filled.
                let context = await makeContext()
                formVM = WinlinkFormComposeViewModel(template: template, context: context, store: store)
                isPreparing = false
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: template.icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(template.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isPreparing)
        .help(template.summary)
    }
}

/// Native editor for one form: sections mirror the paper form, values
/// arrive auto-filled from the operator profile and position.
struct WinlinkFormEditorView: View {

    @ObservedObject var viewModel: WinlinkFormComposeViewModel
    var onBack: () -> Void
    var onQueue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    onBack()
                } label: {
                    Label("Forms", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Image(systemName: viewModel.template.icon)
                    .foregroundStyle(.tint)
                Text(viewModel.template.title)
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            Form {
                ForEach(viewModel.sections, id: \.name) { section in
                    Section(section.name) {
                        ForEach(section.fields) { field in
                            fieldView(field)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let error = viewModel.validationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { onBack() }
                Button("Queue for Sending") { onQueue() }
                    .keyboardShortcut(.defaultAction)
                    .help("Renders the form (body + Winlink Express form data) and queues it in your Outbox.")
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func fieldView(_ field: WinlinkFormField) -> some View {
        let binding = Binding(
            get: { viewModel.values[field.id] ?? "" },
            set: { viewModel.values[field.id] = $0 })

        switch field.kind {
        case .text:
            TextField(requiredLabel(field), text: binding,
                      prompt: field.placeholder.isEmpty ? nil : Text(field.placeholder))
                .help(field.help)

        case .multiline:
            VStack(alignment: .leading, spacing: 3) {
                Text(requiredLabel(field)).font(.callout)
                TextEditor(text: binding)
                    .frame(minHeight: 70)
                    .font(.body)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
            .help(field.help)

        case .choice(let options):
            Picker(requiredLabel(field), selection: binding) {
                ForEach(options, id: \.self) { option in
                    Text(option.isEmpty ? "—" : option).tag(option)
                }
            }
            .help(field.help)

        case .yesNoUnknown:
            HStack {
                Text(field.label)
                Spacer()
                Picker("", selection: binding) {
                    Text("Yes").tag("YES")
                    Text("No").tag("NO")
                    Text("Unknown").tag("UNK")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
            .help(field.help.isEmpty ? "Is \(field.label) functioning at your location?" : field.help)
        }
    }

    private func requiredLabel(_ field: WinlinkFormField) -> String {
        field.required ? "\(field.label) *" : field.label
    }
}
