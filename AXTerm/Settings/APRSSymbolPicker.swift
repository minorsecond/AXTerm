import SwiftUI

/// Pick an APRS symbol from the complete approved set — both tables, every
/// code — searchable by label or code. Selection sets the beacon's symbol
/// table and code. Overlays are handled by the editor's separate overlay
/// field; here the tables are the canonical `/` and `\`.
struct APRSSymbolPicker: View {
    /// Current selection (table, code) and a setter.
    let selectedTable: Character
    let selectedCode: Character
    let onSelect: (Character, Character) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [APRSSymbol] {
        let all = APRSSymbolCatalog.all
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.label.lowercased().contains(q)
                || String($0.code) == q
                || "\($0.table)\($0.code)".lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose an APRS symbol").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            TextField("Search symbols (label or code)", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            List(results) { symbol in
                Button {
                    onSelect(symbol.table, symbol.code)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        // The symbol itself. Choosing one from a list of
                        // names and byte pairs meant picking blind.
                        APRSSymbolView(table: symbol.table, code: symbol.code, size: 18)
                            .foregroundStyle(.primary)
                            .frame(width: 22)
                        // Table + code, monospaced, as the on-air bytes.
                        Text("\(String(symbol.table))\(String(symbol.code))")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 34, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(symbol.label)
                        Spacer()
                        Text(symbol.table == "/" ? "Primary" : "Alternate")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if symbol.table == selectedTable && symbol.code == selectedCode {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 420, minHeight: 460)
    }
}
