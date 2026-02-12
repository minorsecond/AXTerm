import SwiftUI
import AppKit

struct DestinationPickerControl: View {
    @ObservedObject var viewModel: DestinationPickerViewModel
    var externalText: String
    var groups: [ConnectSuggestionGroup]
    var disabled: Bool
    var compactLabel: Bool = true
    let onDestinationChanged: (String) -> Void
    let onDestinationCommitted: (String) -> Void
    var onViewStationDetails: ((String) -> Void)? = nil

    @FocusState private var textFieldFocused: Bool
    @State private var showPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 7) {
                Text("To:")
                    .font(.system(size: compactLabel ? 11 : 12, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    TextField("Callsign-SSID", text: textBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .focused($textFieldFocused)
                        .onSubmit {
                            commitFromKeyboard()
                        }
                        .accessibilityIdentifier("connectBar.destinationField")

                    Button {
                        if showPopover {
                            showPopover = false
                        } else {
                            viewModel.openSuggestions()
                            showPopover = true
                            textFieldFocused = true
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show destination suggestions")
                    .disabled(disabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(borderColor, lineWidth: borderLineWidth)
                )
                .popover(isPresented: $showPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    suggestionsPopover
                }
            }

            Text(viewModel.validationState.inlineError ?? " ")
                .font(.caption2)
                .foregroundStyle(.red.opacity(0.85))
                .lineLimit(1)
                .frame(height: 12, alignment: .leading)
                .opacity(viewModel.validationState.inlineError == nil ? 0 : 1)
                .accessibilityHidden(viewModel.validationState.inlineError == nil)
        }
        .disabled(disabled)
        .onAppear {
            viewModel.syncExternalDestination(externalText)
            viewModel.updateDataSources(groups: groups)
        }
        .onChange(of: externalText) { _, newValue in
            if !textFieldFocused {
                viewModel.syncExternalDestination(newValue)
            }
        }
        .onChange(of: groups) { _, newValue in
            viewModel.updateDataSources(groups: newValue)
        }
        .onChange(of: textFieldFocused) { _, isFocused in
            if !isFocused {
                showPopover = false
            }
        }
        .onMoveCommand { direction in
            guard showPopover else {
                if direction == .down {
                    viewModel.openSuggestions()
                    showPopover = true
                }
                return
            }
            switch direction {
            case .up:
                viewModel.moveHighlight(up: true)
            case .down:
                viewModel.moveHighlight(up: false)
            default:
                break
            }
        }
        .onExitCommand {
            showPopover = false
        }
    }

    private var borderColor: Color {
        if case .invalid = viewModel.validationState {
            return .red.opacity(0.55)
        }
        return Color(nsColor: .separatorColor).opacity(0.45)
    }

    private var borderLineWidth: CGFloat {
        if case .invalid = viewModel.validationState {
            return 1
        }
        return 0.6
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { viewModel.typedText },
            set: { newValue in
                viewModel.handleTypedTextChanged(newValue, autoOpenPopover: textFieldFocused)
                onDestinationChanged(DestinationPickerViewModel.normalizeCandidate(viewModel.typedText))
            }
        )
    }

    @ViewBuilder
    private var suggestionsPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !viewModel.visibleSections.isEmpty || viewModel.didYouMeanRow != nil {
                SuggestionListView(
                    sections: sectionsForList,
                    highlightedItemID: $viewModel.highlightedSuggestionID,
                    onSelect: { row in
                        selectRow(row)
                    },
                    rowContent: { row, isHighlighted in
                        suggestionRow(row: row, isHighlighted: isHighlighted)
                    }
                )

                if let didYouMean = viewModel.didYouMeanRow {
                    Divider()
                    Button {
                        selectRow(didYouMean)
                    } label: {
                        HStack(spacing: 8) {
                            Text(didYouMean.secondaryText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(didYouMean.callsign)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No recent stations")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Type a callsign to connect.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
            }
        }
        .padding(8)
        .frame(width: 340)
    }

    private var sectionsForList: [SuggestionListSection<DestinationSuggestionRow>] {
        viewModel.visibleSections.map {
            SuggestionListSection(id: $0.id, title: $0.title, items: $0.rows)
        }
    }

    @ViewBuilder
    private func suggestionRow(row: DestinationSuggestionRow, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.callsign)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    if row.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                }

                Text(row.aliasText ?? row.secondaryText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contextMenu {
            Button(viewModel.isFavorite(row.callsign) ? "Unfavorite" : "Favorite") {
                viewModel.toggleFavorite(row.callsign)
            }
            Button("Copy Callsign") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.callsign, forType: .string)
            }
            Button("View Station Details…") {
                onViewStationDetails?(row.callsign)
            }
            if !DestinationPickerViewModel.normalizeCandidate(viewModel.typedText).isEmpty,
               DestinationPickerViewModel.normalizeCandidate(viewModel.typedText) != row.callsign {
                if viewModel.hasAliasLink(between: viewModel.typedText, and: row.callsign) {
                    Button("Remove Link") {
                        viewModel.removeAliasLink(between: viewModel.typedText, and: row.callsign)
                    }
                } else {
                    Button("Link \(DestinationPickerViewModel.normalizeCandidate(viewModel.typedText)) ↔ \(row.callsign)") {
                        viewModel.registerAliasEvidence(between: viewModel.typedText, and: row.callsign, source: .userConfirmed)
                    }
                }
            }
        }
    }

    private func selectRow(_ row: DestinationSuggestionRow) {
        viewModel.selectSuggestion(row)
        let selected = DestinationPickerViewModel.normalizeCandidate(row.callsign)
        onDestinationChanged(selected)
        onDestinationCommitted(selected)
    }

    private func commitFromKeyboard() {
        guard let committed = viewModel.commitSelection() else { return }
        onDestinationChanged(committed)
        onDestinationCommitted(committed)
    }
}
