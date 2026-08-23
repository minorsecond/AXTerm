import SwiftUI

/// Renders a received Winlink form (parsed from its
/// `RMS_Express_Form_*.xml` attachment) as a native field table — no
/// HTML viewer needed.
struct WinlinkReceivedFormView: View {

    let form: WinlinkReceivedForm

    private var formName: String {
        let base = (form.displayForm as NSString).deletingPathExtension
        return base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: " Viewer", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " Initial", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
    }

    private var filledVariables: [(name: String, value: String)] {
        form.variables.filter { !$0.value.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.tint)
                Text(formName.isEmpty ? "Winlink Form" : formName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !form.gridSquare.isEmpty {
                    Text(form.gridSquare)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .help("Sender's grid square at submission time")
                }
            }
            .help("This message carries Winlink form data. AXTerm renders the fields natively; Winlink Express users see the same form in its official viewer.")

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(filledVariables, id: \.name) { variable in
                    GridRow {
                        Text(prettyName(variable.name))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(variable.value)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    /// "contactname" → "Contactname", "exercise_id" → "Exercise id".
    private func prettyName(_ name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
