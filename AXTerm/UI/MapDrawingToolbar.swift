import SwiftUI
import CoreLocation

/// Mode picker and in-progress controls for drawing on the map.
///
/// Appears as a strip only while drawing. A permanent toolbar of drawing tools
/// would suggest the map is a drawing surface first, when it is a station map
/// that can also be drawn on — and would take room from the thing the operator
/// actually came to look at.
struct MapDrawingToolbar: View {

    @Binding var session: MapDrawingSession
    /// Called with the finished geometry when the operator taps Done.
    let onComplete: (ShapefileReader.Geometry) -> Void

    var body: some View {
        HStack(spacing: 8) {
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

            if session.isDrawing {
                if let progress = session.progressText {
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.1), lineWidth: 0.5))
        .animation(.default, value: session.isDrawing)
        .animation(.default, value: session.vertices.count)
    }
}
