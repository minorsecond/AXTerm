//
//  PayloadFormatter.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

nonisolated enum PayloadFormatter {
    static let defaultBytesPerLine: Int = 16

    static func hexString(_ data: Data, bytesPerLine: Int = defaultBytesPerLine) -> String {
        guard !data.isEmpty else { return "" }
        var result = ""
        for (index, byte) in data.enumerated() {
            if index > 0 && index % bytesPerLine == 0 {
                result += "\n"
            } else if index > 0 {
                result += " "
            }
            result += String(format: "%02X", byte)
        }
        return result
    }

    static func asciiString(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        return data.map { byte in
            if byte >= 0x20 && byte <= 0x7E,
               let scalar = UnicodeScalar(Int(byte)) {
                return Character(scalar)
            }
            return "·"
        }.map(String.init).joined()
    }
}
