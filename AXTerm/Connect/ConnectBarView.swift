import SwiftUI

struct ConnectBarView: View {
    @ObservedObject var viewModel: ConnectBarViewModel
    let context: ConnectSourceContext
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Connect Type", selection: modeBinding) {
                    Text("AX.25").tag(ConnectBarMode.ax25)
                    Text("AX.25 via Digi").tag(ConnectBarMode.ax25ViaDigi)
                    Text("NET/ROM").tag(ConnectBarMode.netrom)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                EditableComboBox(
                    text: toCallBinding,
                    placeholder: "Destination (CALL-SSID)",
                    items: viewModel.flatToSuggestions,
                    width: 230,
                    onCommit: {}
                )
                .frame(width: 240)

                Spacer(minLength: 8)

                Button {
                    onConnect()
                } label: {
                    Label("Connect", systemImage: "link")
                }
                .disabled(!viewModel.validationErrors.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if viewModel.canEditDigis {
                viaEditor
            }

            if viewModel.canEditNetRomRouting {
                netRomEditor
            }

            if let note = viewModel.inlineNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if !viewModel.validationErrors.isEmpty {
                Text(viewModel.validationErrors.joined(separator: " • "))
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }

            if !viewModel.warningMessages.isEmpty {
                Text(viewModel.warningMessages.joined(separator: " • "))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            if let warning = viewModel.routeOverrideWarning {
                Text(warning)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                if viewModel.canEditDigis {
                    Menu {
                        Section("Recent paths") {
                            ForEach(viewModel.recentPathPresets, id: \.self) { path in
                                Button(path.joined(separator: " ")) {
                                    viewModel.applyPathPreset(path)
                                }
                            }
                        }
                        Section("Observed paths") {
                            ForEach(viewModel.observedPathPresets, id: \.self) { path in
                                Button(path.joined(separator: " ")) {
                                    viewModel.applyPathPreset(path)
                                }
                            }
                        }
                        Section("Known digipeaters") {
                            ForEach(viewModel.knownDigiPresets, id: \.self) { digi in
                                Button(digi) {
                                    viewModel.appendDigipeaters([digi])
                                }
                            }
                        }
                    } label: {
                        Label("Path Tools", systemImage: "slider.horizontal.3")
                    }
                    .disabled(viewModel.recentPathPresets.isEmpty && viewModel.observedPathPresets.isEmpty && viewModel.knownDigiPresets.isEmpty)
                    .font(.system(size: 11))
                    .controlSize(.small)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
        )
        .onAppear {
            viewModel.applyContext(context)
        }
    }

    private var modeBinding: Binding<ConnectBarMode> {
        Binding(
            get: { viewModel.mode },
            set: { viewModel.setMode($0, for: context) }
        )
    }

    private var toCallBinding: Binding<String> {
        Binding(
            get: { viewModel.toCall },
            set: { viewModel.applySuggestedTo($0) }
        )
    }

    private var viaEditor: some View {
        HStack(spacing: 8) {
            Label("Path", systemImage: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if viewModel.viaDigipeaters.isEmpty {
                        Text("Direct")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.08))
                            )
                    }

                    ForEach(Array(viewModel.viaDigipeaters.enumerated()), id: \.offset) { idx, token in
                        HStack(spacing: 4) {
                            Text(token)
                                .font(.system(size: 10, design: .monospaced))
                            Button {
                                viewModel.removeDigi(at: idx)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(
                            Capsule()
                                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                        )
                        .contextMenu {
                            Button("Move Earlier") {
                                viewModel.moveDigiLeft(at: idx)
                            }
                            .disabled(idx == 0)

                            Button("Move Later") {
                                viewModel.moveDigiRight(at: idx)
                            }
                            .disabled(idx >= viewModel.viaDigipeaters.count - 1)
                        }
                    }
                }
            }
            .frame(maxWidth: 320)

            TextField("Add digis (comma or space separated)", text: $viewModel.pendingViaTokenInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 200)
                .onSubmit {
                    viewModel.ingestViaInput()
                }

            Button("Add") {
                viewModel.ingestViaInput()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("\(viewModel.viaHopCount) hops")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(viewModel.viaHopCount > 2 ? .orange : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(
                    Capsule()
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                )
        }
    }

    private var netRomEditor: some View {
        HStack(spacing: 8) {
            Label("Route", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Text(viewModel.routePreview)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 320, alignment: .leading)

            Picker("Next hop", selection: $viewModel.nextHopSelection) {
                Text("Auto").tag(ConnectBarViewModel.autoNextHopID)
                ForEach(viewModel.nextHopOptions.filter { $0 != ConnectBarViewModel.autoNextHopID }, id: \.self) { hop in
                    Text(hop).tag(hop)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)
            .onChange(of: viewModel.nextHopSelection) { _, _ in
                viewModel.refreshRoutePreview()
            }
        }
    }
}
