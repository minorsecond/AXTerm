//
//  RawStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation

nonisolated protocol RawStore: Sendable {
    func append(_ entry: RawEntryRecord) throws
    func loadRecent(limit: Int) throws -> [RawEntryRecord]
    func deleteAll() throws
    func pruneIfNeeded(retentionLimit: Int) throws
}
