//
//  RawEntryEncoding.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation

nonisolated enum RawEntryEncoding {
    static func encodeHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
