import SwiftUI

struct DestinationPickerControl: View {
    @ObservedObject var viewModel: DestinationPickerViewModel
    var externalText: String
    var groups: [ConnectSuggestionGroup]
    /// Destination → the node that listed it, so a reachable row can name the
    /// route instead of leaving the operator to look it up.
    var reachableVia: [String: String] = [:]
    var disabled: Bool
    var compactLabel: Bool = true
    /// Reserve a row beneath the field for the inline validation error. Off in
    /// the compact connect bar, where that always-present (even if invisible)
    /// row made the control taller than its neighbours and pushed the field
    /// above their vertical centre — the red border already flags an invalid
    /// callsign there.
    var showsInlineError: Bool = true
    let onDestinationChanged: (String) -> Void
    let onDestinationCommitted: (String) -> Void
    var onViewStationDetails: ((String) -> Void)? = nil

    @FocusState private var textFieldFocused: Bool
    @State private var showPopover = false
    @State private var userInitiatedPopover = false

    /// The reserved inline-error row, omitted entirely in compact mode.
    @ViewBuilder private var inlineErrorRow: some View {
        if showsInlineError {
            Text(viewModel.validationState.inlineError ?? " ")
                .font(.caption2)
                .foregroundStyle(.red.opacity(0.85))
                .lineLimit(1)
                .frame(height: 12, alignment: .leading)
                .opacity(viewModel.validationState.inlineError == nil ? 0 : 1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 7) {
                Text("To:")
                    .font(.system(size: compactLabel ? 11 : 12, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    // On touch this is a *button*, not a text field.
                    //
                    // Tapping a field raises the keyboard, and the keyboard
                    // then covers the very list the tap was meant to reveal —
                    // so the operator ends up typing a callsign they can see
                    // in a list they cannot reach. Opening the picker instead
                    // puts the list and its own search field above the
                    // keyboard, where both fit.
                    #if os(iOS)
                    Button {
                        userInitiatedPopover = true
                        showPopover = true
                    } label: {
                        Text(viewModel.typedText.isEmpty ? "Callsign-SSID" : viewModel.typedText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(viewModel.typedText.isEmpty ? .tertiary : .primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .accessibilityIdentifier("connectBar.destinationField")
                    .accessibilityLabel("Connect to")
                    .accessibilityValue(viewModel.typedText.isEmpty ? "No station chosen" : viewModel.typedText)
                    #else
                    TextField("Callsign-SSID", text: textBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .focused($textFieldFocused)
                        .onSubmit { commitFromKeyboard() }
                        .accessibilityIdentifier("connectBar.destinationField")
                    #endif

                    Button {
                        if showPopover {
                            showPopover = false
                            userInitiatedPopover = false
                        } else {
                            userInitiatedPopover = true
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
                        .fill(Color(platform: .platformCardBackground).opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(borderColor, lineWidth: borderLineWidth)
                )
                // A popover anchored to this field has nowhere to go once the
                // on-screen keyboard claims the bottom half of the screen: it
                // is squeezed into whatever strip is left, which on an iPad in
                // portrait was about one row tall and made the station
                // unpickable. A sheet owns its own space and can be scrolled.
                #if os(iOS)
                .sheet(isPresented: $showPopover) {
                    suggestionsSheet
                }
                #else
                .popover(isPresented: $showPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    suggestionsPopover
                }
                #endif
            }
            .help(viewModel.validationState.inlineError ?? "")

            inlineErrorRow
                .accessibilityHidden(viewModel.validationState.inlineError == nil)
        }
        .disabled(disabled)
        .onAppear {
            viewModel.syncExternalDestination(externalText)
            viewModel.updateDataSources(groups: groups, reachableVia: reachableVia)
        }
        .onChange(of: externalText) { _, newValue in
            if !textFieldFocused {
                viewModel.syncExternalDestination(newValue)
            }
        }
        .onChange(of: groups) { _, newValue in
            viewModel.updateDataSources(groups: newValue, reachableVia: reachableVia)
        }
        .onChange(of: textFieldFocused) { _, isFocused in
            if !isFocused {
                showPopover = false
                userInitiatedPopover = false
            }
        }
        // Arrow keys and Escape drive the suggestion list where there is a
        // keyboard. On touch the operator taps a suggestion instead, and the
        // popover is dismissed by tapping outside it.
        #if os(macOS)
        .onMoveCommand { direction in
            if direction == .down && textFieldFocused {
                userInitiatedPopover = true
                showPopover = true
            }
            guard showPopover else { return }
            switch direction {
            case .up: viewModel.moveHighlight(up: true)
            case .down: viewModel.moveHighlight(up: false)
            default: break
            }
        }
        .onExitCommand {
            showPopover = false
            userInitiatedPopover = false
        }
        #endif
    }

    private var borderColor: Color {
        if case .invalid = viewModel.validationState { return .red.opacity(0.55) }
        return Color(platform: .platformSeparator).opacity(0.45)
    }

    private var borderLineWidth: CGFloat {
        if case .invalid = viewModel.validationState { return 1 }
        return 0.6
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { viewModel.typedText },
            set: { newValue in
                viewModel.handleTypedTextChanged(newValue, autoOpenPopover: false)
                if textFieldFocused {
                    if !viewModel.typedText.isEmpty {
                        showPopover = true
                    } else if userInitiatedPopover {
                        showPopover = true
                    }
                }
                onDestinationChanged(DestinationPickerViewModel.normalizeCandidate(viewModel.typedText))
            }
        )
    }

#if os(iOS)
    /// The same suggestions, in a sheet the keyboard cannot squash.
    ///
    /// Dismissing the keyboard on appear is deliberate: the operator is
    /// choosing from a list now, not typing, and leaving it up would cover the
    /// list it was covering before.
    private var suggestionsSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Typing lives here, above the keyboard, alongside the list it
                // filters — rather than in a field the keyboard then buries.
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Callsign-SSID", text: textBinding)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($textFieldFocused)
                        .submitLabel(.go)
                        .onSubmit {
                            commitFromKeyboard()
                            showPopover = false
                        }
                    if !viewModel.typedText.isEmpty {
                        Button {
                            viewModel.typedText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                suggestionsPopover
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .navigationTitle("Connect To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showPopover = false
                        textFieldFocused = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        commitFromKeyboard()
                        showPopover = false
                        textFieldFocused = false
                    }
                    .disabled(DestinationPickerViewModel
                        .normalizeCandidate(viewModel.typedText).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Focus the search field, not the bar behind the sheet: the operator
        // opened this to choose, and a keyboard over a half-height sheet still
        // leaves the list visible above it.
        .onAppear { textFieldFocused = true }
        .onDisappear { textFieldFocused = false }
    }
#endif

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
                    Text("No matching stations")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Type to filter suggestions")
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
                ClipboardWriter.copy(row.callsign)
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
        // Choosing from the sheet is the whole answer, so the sheet goes.
        // Leaving it open makes the operator hunt for a confirm button after
        // they have already made the choice. On macOS the popover closes on
        // its own when focus leaves the field.
        #if os(iOS)
        showPopover = false
        textFieldFocused = false
        #endif
    }

    private func commitFromKeyboard() {
        guard let committed = viewModel.commitSelection() else { return }
        onDestinationChanged(committed)
        onDestinationCommitted(committed)
    }
}
