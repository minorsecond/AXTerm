//
//  BBSUploadPolicy.swift
//  AXTerm
//
//  Whether to accept a file from a caller, and what to call it on disk.
//

import Foundation

/// The rules for accepting an upload.
///
/// Sharing files out and accepting files in are different decisions with
/// different risks, so they are different settings. This one runs unattended,
/// against a filename chosen by whoever is on the other end of the radio, and
/// every rule here exists because of something that name could otherwise do.
nonisolated struct BBSUploadPolicy: Equatable, Sendable {

    /// Off unless the operator turned it on, separately from downloads.
    var isEnabled: Bool
    /// Whether the operator has nominated somewhere to put uploads.
    var hasInbox: Bool
    /// Refused above this. Default is small on purpose: 100 KB is twenty
    /// minutes of channel, and a caller who needs more should ask first.
    var maxFileBytes: Int
    /// Total the inbox may hold before uploads stop being accepted.
    var quotaBytes: Int
    var usedBytes: Int
    var uploadsThisCall: Int
    var maxUploadsPerCall: Int

    init(isEnabled: Bool = false,
         hasInbox: Bool = false,
         maxFileBytes: Int = 100 * 1024,
         quotaBytes: Int = 20 * 1024 * 1024,
         usedBytes: Int = 0,
         uploadsThisCall: Int = 0,
         maxUploadsPerCall: Int = 3) {
        self.isEnabled = isEnabled
        self.hasInbox = hasInbox
        self.maxFileBytes = maxFileBytes
        self.quotaBytes = quotaBytes
        self.usedBytes = usedBytes
        self.uploadsThisCall = uploadsThisCall
        self.maxUploadsPerCall = maxUploadsPerCall
    }

    enum Decision: Equatable, Sendable {
        case accept(filename: String)
        /// Told to the caller as-is. A refusal that does not say why is
        /// indistinguishable from a broken station.
        case reject(reason: String)

        var isAccept: Bool { if case .accept = self { true } else { false } }
    }

    /// Applied to the transfer's own header, before a single byte is written.
    func decide(filename: String, size: Int) -> Decision {
        guard isEnabled else {
            return .reject(reason: "this station does not accept uploads")
        }
        guard hasInbox else {
            return .reject(reason: "the sysop has not set somewhere to put uploads")
        }
        guard uploadsThisCall < maxUploadsPerCall else {
            return .reject(reason: "\(maxUploadsPerCall) uploads per call is the limit")
        }
        guard size > 0 else {
            return .reject(reason: "the file is empty")
        }
        guard size <= maxFileBytes else {
            return .reject(reason: "too large — \(BBSFileIndex.size(maxFileBytes)) is the limit here")
        }
        guard usedBytes + size <= quotaBytes else {
            return .reject(reason: "the upload area is full")
        }
        guard let safe = Self.sanitize(filename) else {
            return .reject(reason: "that filename cannot be used here")
        }
        return .accept(filename: safe)
    }

    /// Reduces a caller-supplied name to something safe to create.
    ///
    /// The name arrives over the air from a stranger and ends up as a file on
    /// the operator's disk, so this is deliberately a whitelist rather than a
    /// list of things to strip: anything not explicitly allowed becomes an
    /// underscore, and a name that survives to nothing is refused rather than
    /// replaced with a guess.
    ///
    /// Returns nil when nothing usable remains.
    static func sanitize(_ filename: String) -> String? {
        // Directory components go first: the name must be a leaf, and
        // "../../.ssh/authorized_keys" must not become "authorized_keys" by
        // accident of ordering either — it is refused below for being hidden.
        var name = (filename as NSString).lastPathComponent
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        // No hidden files. A caller has no business creating one, and it is
        // how a dotfile ends up somewhere the operator never looks.
        while name.hasPrefix(".") { name.removeFirst() }
        guard !name.isEmpty else { return nil }

        // ASCII only. `CharacterSet.alphanumerics` would admit the whole of
        // Unicode, and a name a stranger chose is rendered back to the
        // operator — lookalike characters and bidirectional overrides are not
        // worth accepting for a filename on a packet link.
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- ")
        name = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        name = name.trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty, name != "." else { return nil }
        // A name made entirely of punctuation is not a filename anyone meant
        // to send; refuse rather than inventing one.
        guard name.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        // Long enough for anything real; short enough that it cannot be used
        // to make a name nobody can read or delete.
        if name.count > 64 {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            let room = ext.isEmpty ? 64 : max(1, 63 - ext.count)
            name = ext.isEmpty
                ? String(stem.prefix(room))
                : String(stem.prefix(room)) + "." + ext
        }
        return name
    }

    /// A name that does not already exist in `taken`.
    ///
    /// Uploads never overwrite. A caller being able to replace a file the
    /// operator already has is a way to change what the station serves.
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let lowercased = Set(taken.map { $0.lowercased() })
        guard lowercased.contains(name.lowercased()) else { return name }

        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            if !lowercased.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }
}
