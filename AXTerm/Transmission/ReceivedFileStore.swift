//
//  ReceivedFileStore.swift
//  AXTerm
//
//  Where files received over the air are written, and how they are named.
//
//  The folder has to be somewhere the operator can find without help. On the
//  Mac that is Downloads, which the sandbox grants and Finder shows. On iOS
//  an app's Downloads folder is private to the app, so a file saved there
//  existed and could not be reached; Documents is the folder the Files app
//  shows under "On My iPhone › AXTerm" once the app declares file sharing.
//

import Foundation

nonisolated enum ReceivedFileStore {
    /// The folder's name, inside Downloads on the Mac and Documents on iOS.
    /// Named in the UI as well, so the operator knows what to look for.
    static let folderName = "AXTerm Transfers"

    /// The platform a folder decision is made for. A parameter rather than
    /// `#if` inside the decision so both answers can be tested on one machine.
    enum Platform: Equatable, Sendable {
        case macOS
        case iOS

        static var current: Platform {
            #if os(macOS)
            return .macOS
            #else
            return .iOS
            #endif
        }
    }

    /// The folder received files go in.
    ///
    /// Mac: `~/Downloads/AXTerm Transfers`, or Documents if Downloads is
    /// missing. iOS: `Documents/AXTerm Transfers` only. Downloads is never
    /// used on iOS even if the system hands one out, because nothing outside
    /// the app can open it.
    static func folder(for platform: Platform, downloads: URL?, documents: URL?) -> URL? {
        switch platform {
        case .macOS:
            return (downloads ?? documents)?.appendingPathComponent(folderName, isDirectory: true)
        case .iOS:
            return documents?.appendingPathComponent(folderName, isDirectory: true)
        }
    }

    /// The folder for this device, from the file manager's standard locations.
    static func defaultFolder(fileManager: FileManager = .default,
                              platform: Platform = .current) -> URL? {
        folder(for: platform,
               downloads: fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
               documents: fileManager.urls(for: .documentDirectory, in: .userDomainMask).first)
    }

    /// A safe local name for a file name that came from another station.
    ///
    /// The name is untrusted: it is whatever the far end typed or its
    /// software chose. Only the last path component is kept, so "../x" or
    /// "C:\\DOS\\X.ZIP" cannot climb out of the folder; control characters
    /// and the characters Finder and Files refuse are replaced; leading dots
    /// go, so nothing arrives hidden; and the length is capped well under
    /// the file system's limit.
    static func sanitize(_ name: String) -> String {
        let separators = CharacterSet(charactersIn: "/\\:")
        let lastComponent = (name.components(separatedBy: separators).last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = String(lastComponent.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{7F}" {
                return "_"
            }
            return Character(scalar)
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > maxNameLength {
            let ext = (cleaned as NSString).pathExtension
            let base = (cleaned as NSString).deletingPathExtension
            let keep = max(1, maxNameLength - (ext.isEmpty ? 0 : ext.count + 1))
            cleaned = String(base.prefix(keep)) + (ext.isEmpty ? "" : "." + ext)
            cleaned = String(cleaned.prefix(maxNameLength))
        }
        return cleaned.isEmpty ? fallbackName : cleaned
    }

    static let fallbackName = "received-file"
    static let maxNameLength = 200

    /// The first name in `folder` that nothing is using: "name.ext", then
    /// "name 2.ext", "name 3.ext". Received files never overwrite anything,
    /// including an earlier copy of themselves.
    static func uniqueURL(for name: String, in folder: URL,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = folder.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var counter = 2
        while true {
            let candidate = folder.appendingPathComponent(
                ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }

    enum SaveError: Error, LocalizedError, Equatable {
        case noFolder
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFolder:
                return "There is no folder to save received files in."
            case .writeFailed(let detail):
                return "The file could not be saved in \(ReceivedFileStore.folderName): \(detail)"
            }
        }
    }

    /// Writes a received file under a sanitized, unused name and returns
    /// where it went.
    ///
    /// `.withoutOverwriting` makes the no-overwrite rule hold even if another
    /// file of the same name appears between choosing the name and writing:
    /// the write fails and the next name is tried.
    static func save(_ data: Data, suggestedName: String, in folder: URL?,
                     fileManager: FileManager = .default) throws -> URL {
        guard let folder else { throw SaveError.noFolder }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw SaveError.writeFailed(error.localizedDescription)
        }
        let name = sanitize(suggestedName)
        var lastError: Error?
        for _ in 0..<50 {
            let target = uniqueURL(for: name, in: folder) { fileManager.fileExists(atPath: $0.path) }
            do {
                try data.write(to: target, options: [.withoutOverwriting])
                return target
            } catch {
                lastError = error
                if !fileManager.fileExists(atPath: target.path) { break }
            }
        }
        throw SaveError.writeFailed(lastError?.localizedDescription ?? "unknown error")
    }
}
