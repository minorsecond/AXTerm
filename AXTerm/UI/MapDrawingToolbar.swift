import SwiftUI
import CoreLocation

/// Mode picker and in-progress controls for drawing on the map.
///
/// On the Mac the picker is always there: a segmented strip at the top of the
/// map, with Undo, Done and Cancel appearing beside it while a shape is being
/// drawn. On a phone or a tablet the same strip sat over the middle of the
/// map at all times, which suggested the map was a drawing surface first,
/// when it is a station map that can also be drawn on — so there the modes
/// are started from a menu and this view appears only while drawing, saying
/// which tool is active and what is left to do.
struct MapDrawingToolbar: View {

    @Binding var session: MapDrawingSession
    /// Called with the finished geometry when the operator taps Done.
    let onComplete: (ShapefileReader.Geometry) -> Void
    /// Whether the mode picker is part of the strip. False makes the strip
    /// appear only while drawing, with the active tool named instead.
    var showsModePicker = true

    var body: some View {
        if showsModePicker || session.isDrawing {
            strip
        }
    }

    private var strip: some View {
        HStack(spacing: 8) {
            if showsModePicker {
                modePicker
            } else {
                Label(session.mode.title, systemImage: session.mode.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
            }

            if session.isDrawing {
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                if session.mode.isMultiPoint {
                    Button("Undo") { session.undoVertex() }
                        .controlSize(.small)
                        .disabled(!session.canUndo)

                    Button("Done") {
                        guard let geometry = session.geometry() else { return }
                        onComplete(geometry)
                    }
                    .controlSize(.small)
                    .disabled(!session.canComplete)
                    .keyboardShortcut(.defaultAction)
                }

                Button("Cancel") { session.cancel() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, showsModePicker ? 8 : 14)
        .padding(.vertical, showsModePicker ? 5 : 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(showsModePicker ? 0 : 0.15), radius: 6, y: 2)
        .animation(.default, value: session.isDrawing)
        .animation(.default, value: session.vertices.count)
    }

    /// What to do next. The session says it for lines and areas; a single
    /// mark has no count to report, so the instruction is spelled out here.
    private var hint: String? {
        session.progressText ?? (session.mode == .point ? "Tap the map to place it" : nil)
    }

    private var modePicker: some View {
            Picker("", selection: Binding(
                get: { session.mode },
                set: { newMode in
                    // Switching tools discards a half-drawn shape rather than
                    // carrying its vertices into a different geometry, where
                    // three taps meant as an area would become a line.
                    if newMode == .off { session.cancel() } else { session.begin(newMode) }
                })) {
                ForEach(MapDrawingMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .explain(MapDrawingMode.allCases
                .map { "\($0.title): \($0.help)" }
                .joined(separator: "\n\n"))
    }
}
