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

    /// The type handed to the iOS exporter: this file's own type when the
    /// exporter document declares it, and plain data otherwise.
    ///
    /// The document has to declare every type it is asked to write. It
    /// declared only `.data` while the exporter was handed `.jpeg` or `.pdf`,
    /// and a type the document does not list is one the exporter is entitled
    /// to refuse. Falling back to `.data` for anything unlisted keeps the
    /// file's own name and bytes, which is what matters.
    var exportContentType: UTType {
        let type = contentType
        return ExportableFileDocument.writableContentTypes.contains(type) ? type : .data
    }

    /// The types the exporter document declares: the ones Winlink traffic
    /// actually carries, plus `.data` for everything else. Types the system
    /// only knows as dynamic identifiers are left out, since they mean
    /// nothing to the Files app.
    static let exportableTypes: [UTType] = {
        let named: [UTType] = [
            .data, .jpeg, .png, .heic, .heif, .gif, .tiff, .bmp, .webP,
            .pdf, .plainText, .utf8PlainText, .text, .rtf, .html, .xml, .json,
            .commaSeparatedText, .zip, .gzip, .mp3, .mpeg4Audio, .wav,
            .mpeg4Movie, .quickTimeMovie,
        ]
        let byExtension = ["txt", "log", "md", "csv", "kml", "kmz", "gpx", "geojson", "shp",
                           "docx", "xlsx", "pptx", "odt", "b2f"]
            .compactMap { UTType(filenameExtension: $0) }
            .filter { !$0.isDynamic }
        var seen = Set<UTType>()
        return (named + byExtension).filter { seen.insert($0).inserted }
    }()
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
/// ever exports through this type. The writable types are listed explicitly
/// and must include whatever `exportContentType` returns; see there.
nonisolated struct ExportableFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { ExportableFile.exportableTypes }
    static var writableContentTypes: [UTType] { ExportableFile.exportableTypes }

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
            contentType: file?.exportContentType ?? .data,
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
