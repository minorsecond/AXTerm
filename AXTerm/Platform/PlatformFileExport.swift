import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// Getting a file out of the app, and getting one in.
///
/// The two platforms disagree about more than spelling here. A Mac has a save
/// panel that returns a destination and then the app writes it; iOS has no
/// filesystem the app may write into on the user's behalf, so the file goes
/// through a document exporter the user drives. Both end with the operator
/// choosing where it lands, which is the part that matters.
///
/// Failure is never silent. An attachment or an ICS-309 log may be the only
/// copy of something that cost airtime to receive, and a save that quietly
/// did nothing looks exactly like one that worked.

/// A file the app wants to hand to the operator.
nonisolated struct ExportableFile: Equatable, Sendable {
    var name: String
    var data: Data

    var contentType: UTType {
        UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }
}

#if os(macOS)

/// Presents a save panel and writes the file. Calls back with an error
/// message on failure, nil on success, and does not call back at all when
/// the operator cancels — a cancel is not a failure to report.
@MainActor
enum PlatformFileExport {
    static func save(_ file: ExportableFile, completion: @escaping @MainActor (String?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try file.data.write(to: url)
                completion(nil)
            } catch {
                completion("Could not save \(file.name): \(error.localizedDescription)")
            }
        }
    }
}

#endif

/// A `FileDocument` wrapper so iOS can hand the bytes to `.fileExporter`.
///
/// Read support is present because `FileDocument` requires it; the app only
/// ever exports through this type.
nonisolated struct ExportableFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var file: ExportableFile

    init(file: ExportableFile) { self.file = file }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        file = ExportableFile(name: configuration.file.filename ?? "file", data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: file.data)
    }
}

extension View {
    /// Hands a file to the operator, however this platform does that.
    ///
    /// On macOS the binding is consumed immediately by a save panel; on iOS
    /// it drives a document exporter. Either way the binding clears when the
    /// interaction ends, and `onError` fires only for real failures — never
    /// for a cancel.
    func exportFile(_ file: Binding<ExportableFile?>,
                    onError: @escaping (String) -> Void) -> some View {
        modifier(FileExportModifier(file: file, onError: onError))
    }
}

private struct FileExportModifier: ViewModifier {
    @Binding var file: ExportableFile?
    let onError: (String) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: file) { _, newValue in
            guard let newValue else { return }
            file = nil
            PlatformFileExport.save(newValue) { error in
                if let error { onError(error) }
            }
        }
        #else
        content.fileExporter(
            isPresented: Binding(get: { file != nil },
                                 set: { if !$0 { file = nil } }),
            document: file.map(ExportableFileDocument.init(file:)),
            contentType: file?.contentType ?? .data,
            defaultFilename: file?.name
        ) { result in
            if case .failure(let error) = result {
                onError("Could not save \(file?.name ?? "file"): \(error.localizedDescription)")
            }
            file = nil
        }
        #endif
    }
}
