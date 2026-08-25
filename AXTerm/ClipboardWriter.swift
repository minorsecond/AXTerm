//
//  ClipboardWriter.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation

/// Copies text to the system clipboard.
///
/// Now a thin name over `PlatformPasteboard` — kept because call sites read
/// better as "copy this to the clipboard" than as a platform concept.
nonisolated enum ClipboardWriter {
    static func copy(_ string: String) {
        PlatformPasteboard.copy(string)
    }
}
