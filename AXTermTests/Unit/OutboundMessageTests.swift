//
//  OutboundMessageTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 02/07/26.
//

import XCTest
import GRDB
@testable import AXTerm

final class OutboundMessageTests: XCTestCase {
    var dbQueue: DatabaseQueue!
    var store: SQLiteOutboundMessageStore!

    override func setUp() async throws {
        try await super.setUp()
        // Use in-memory database for testing
        dbQueue = try DatabaseQueue()
        
        // Run migrations
        try DatabaseManager.migrator.migrate(dbQueue)
        
        store = SQLiteOutboundMessageStore(dbQueue: dbQueue)
    }

    override func tearDown() async throws {
        store = nil
        dbQueue = nil
        try await super.tearDown()
    }

    // MARK: - Migration Tests

    func testTableCreation() throws {
        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("outbound_message"))
            let columns = try db.columns(in: "outbound_message")
            let columnNames = Set(columns.map { $0.name })
            
            let expectedColumns = Set([
                "id", "sessionId", "destCallsign", "createdAt", "payload",
                "mode", "state", "attemptCount", "lastError",
                "bytesTotal", "bytesAcked", "sentAt", "ackedAt"
            ])
            
            XCTAssertTrue(expectedColumns.isSubset(of: columnNames))
        }
    }

    // MARK: - Ordering Tests

    func testFIFOOrdering() throws {
        let sessionId = "session-1"
        let baseDate = Date(timeIntervalSince1970: 1000)
        
        let msg1 = OutboundMessage(
            id: UUID(),
            sessionId: sessionId,
            destCallsign: "CALL",
            createdAt: baseDate,
            text: "Message 1",
            mode: .line
        )
        
        let msg2 = OutboundMessage(
            id: UUID(),
            sessionId: sessionId,
            destCallsign: "CALL",
            createdAt: baseDate.addingTimeInterval(1),
            text: "Message 2",
            mode: .line
        )
        
        let msg3 = OutboundMessage(
            id: UUID(),
            sessionId: sessionId,
            destCallsign: "CALL",
            createdAt: baseDate.addingTimeInterval(2),
            text: "Message 3",
            mode: .line
        )
        
        try store.insertQueued(msg3)
        try store.insertQueued(msg1)
        try store.insertQueued(msg2)
        
        // Fetch next queued - should be msg1 (oldest)
        let next1 = try store.fetchNextQueued(sessionId: sessionId)
        XCTAssertEqual(next1?.id, msg1.id)
        
        // Update state of msg1 to sending
        try store.updateState(
            id: msg1.id,
            newState: .sending,
            sentAt: Date(),
            ackedAt: nil,
            lastError: nil,
            attemptCount: 1,
            bytesAcked: 0
        )
        
        // Fetch next queued - should be msg2
        let next2 = try store.fetchNextQueued(sessionId: sessionId)
        XCTAssertEqual(next2?.id, msg2.id)
        
        // Update state of msg2 to sending
        try store.updateState(
            id: msg2.id,
            newState: .sending,
            sentAt: Date(),
            ackedAt: nil,
            lastError: nil,
            attemptCount: 1,
            bytesAcked: 0
        )
        
        // Fetch next queued - should be msg3
        let next3 = try store.fetchNextQueued(sessionId: sessionId)
        XCTAssertEqual(next3?.id, msg3.id)
    }

    // MARK: - State Machine Tests

    func testAllowedTransitions() {
        let msg = OutboundMessage(
            sessionId: "s1",
            destCallsign: "C",
            text: "test",
            mode: .line
        )
        
        // Queued -> Sending
        XCTAssertTrue(msg.canTransition(to: .sending))
        
        // Queued -> Failed
        XCTAssertTrue(msg.canTransition(to: .failed))
        
        // Queued -> Sent (Not allowed directly)
        XCTAssertFalse(msg.canTransition(to: .sent))
        
        var sendingMsg = msg
        sendingMsg.state = .sending
        
        // Sending -> Sent
        XCTAssertTrue(sendingMsg.canTransition(to: .sent))
        // Sending -> Retrying
        XCTAssertTrue(sendingMsg.canTransition(to: .retrying))
        // Sending -> Failed
        XCTAssertTrue(sendingMsg.canTransition(to: .failed))
        
        var retryingMsg = msg
        retryingMsg.state = .retrying
        
        // Retrying -> Sending
        XCTAssertTrue(retryingMsg.canTransition(to: .sending))
        // Retrying -> Failed
        XCTAssertTrue(retryingMsg.canTransition(to: .failed))
        
        var sentMsg = msg
        sentMsg.state = .sent
        
        // Sent -> anything (Terminal)
        XCTAssertFalse(sentMsg.canTransition(to: .sending))
        XCTAssertFalse(sentMsg.canTransition(to: .failed))
    }
    
    // MARK: - Update Tests
    
    func testUpdateState() throws {
        let msg = OutboundMessage(
            sessionId: "s1",
            destCallsign: "C",
            text: "test",
            mode: .line
        )
        try store.insertQueued(msg)
        
        let sentDate = Date()
        try store.updateState(
            id: msg.id,
            newState: .sending,
            sentAt: sentDate,
            ackedAt: nil,
            lastError: nil,
            attemptCount: 1,
            bytesAcked: 0
        )
        
        let fetched = try XCTUnwrap(store.fetchBySession(sessionId: "s1").first)
        XCTAssertEqual(fetched.state, .sending)
        // Check date equality with small tolerance or exact if possible. 
        // GRDB stores Date as time interval or string depending on setup.
        // Here we just check it is not nil and close enough if we wanted, but existance is good enough for now.
        XCTAssertNotNil(fetched.sentAt)
        XCTAssertEqual(fetched.attemptCount, 1)
    }
    
    func testInvalidTransitionThrows() throws {
        let msg = OutboundMessage(
            sessionId: "s1",
            destCallsign: "C",
            text: "test",
            mode: .line
        )
        try store.insertQueued(msg)
        
        // Try queued -> sent directly
        XCTAssertThrowsError(try store.updateState(
            id: msg.id,
            newState: .sent,
            sentAt: Date(),
            ackedAt: Date(),
            lastError: nil,
            attemptCount: 1,
            bytesAcked: 10
        )) { error in
            guard let pError = error as? OutboundMessageStoreError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            if case .invalidTransition(let from, let to) = pError {
                XCTAssertEqual(from, .queued)
                XCTAssertEqual(to, .sent)
            } else {
                XCTFail("Unexpected OutboundMessageStoreError case")
            }
        }
    }
}
