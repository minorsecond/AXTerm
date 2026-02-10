//
//  ClipboardWriter.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import AppKit

nonisolated enum ClipboardWriter {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
