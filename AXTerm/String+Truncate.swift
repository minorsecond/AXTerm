//
//  String+Truncate.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

extension String {
    func wordSafeTruncate(limit: Int, trailing: String = "...") -> String {
        guard count > limit else { return self }
        let truncatedLimit = max(0, limit - trailing.count)
        let endIndex = index(startIndex, offsetBy: truncatedLimit, limitedBy: endIndex) ?? endIndex
        let prefix = String(self[..<endIndex])

        if let lastWhitespace = prefix.lastIndex(where: { $0.isWhitespace }) {
            let trimmed = prefix[..<lastWhitespace]
            return trimmed.isEmpty ? String(prefix) + trailing : String(trimmed) + trailing
        }

        return prefix + trailing
    }
}
