//
//  MockLogStores.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/2/26.
//

import Foundation
@testable import AXTerm

final class MockConsoleStore: ConsoleStore, @unchecked Sendable {
    private(set) var appendedEntries: [ConsoleEntryRecord] = []
    private(set) var deleteAllCalled = false
    private(set) var pruneCalls: [Int] = []

    func append(_ entry: ConsoleEntryRecord) throws {
        appendedEntries.append(entry)
    }

    func loadRecent(limit: Int) throws -> [ConsoleEntryRecord] {
        Array(appendedEntries.suffix(limit)).reversed()
    }

    func deleteAll() throws {
        deleteAllCalled = true
    }

    func pruneIfNeeded(retentionLimit: Int) throws {
        pruneCalls.append(retentionLimit)
    }
}

final class MockRawStore: RawStore, @unchecked Sendable {
    private(set) var appendedEntries: [RawEntryRecord] = []
    private(set) var deleteAllCalled = false
    private(set) var pruneCalls: [Int] = []

    func append(_ entry: RawEntryRecord) throws {
        appendedEntries.append(entry)
    }

    func loadRecent(limit: Int) throws -> [RawEntryRecord] {
        Array(appendedEntries.suffix(limit)).reversed()
    }

    func deleteAll() throws {
        deleteAllCalled = true
    }

    func pruneIfNeeded(retentionLimit: Int) throws {
        pruneCalls.append(retentionLimit)
    }
}

final class MockEventLogStore: EventLogStore, @unchecked Sendable {
    private(set) var appendedEntries: [AppEventRecord] = []
    private(set) var deleteAllCalled = false
    private(set) var pruneCalls: [Int] = []

    func append(_ entry: AppEventRecord) throws {
        appendedEntries.append(entry)
    }

    func loadRecent(limit: Int) throws -> [AppEventRecord] {
        Array(appendedEntries.suffix(limit)).reversed()
    }

    func deleteAll() throws {
        deleteAllCalled = true
    }

    func pruneIfNeeded(retentionLimit: Int) throws {
        pruneCalls.append(retentionLimit)
    }
}

final class MockEventLogger: EventLogger {
    private(set) var entries: [(AppEventRecord.Level, AppEventRecord.Category, String, [String: String]?)] = []

    func log(level: AppEventRecord.Level, category: AppEventRecord.Category, message: String, metadata: [String: String]?) {
        entries.append((level, category, message, metadata))
    }
}
