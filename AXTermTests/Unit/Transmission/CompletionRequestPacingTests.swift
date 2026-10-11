//
//  CompletionRequestPacingTests.swift
//  AXTermTests
//
//  The sender's "do you have it all?" while it waits for the receiver to
//  confirm a file. Every 2 s outran the round trip through a node relay,
//  where each request crosses every hop (Docs/RemoteAccessPlan.md, part
//  1), so unanswered requests back off exponentially, as TCP's do: 2, 4, 8
//  and so on up to a minute.
//

import XCTest
@testable import AXTerm

final class CompletionRequestPacingTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testTheFirstRequestGoesAtOnce() {
        let pacing = CompletionRequestPacing(startingAt: start)
        XCTAssertTrue(pacing.isDue(at: start))
    }

    func testUnansweredRequestsBackOff() {
        var pacing = CompletionRequestPacing(startingAt: start)
        var now = start
        var gaps: [TimeInterval] = []
        for _ in 0..<8 {
            pacing.sent(at: now)
            var next = now
            while !pacing.isDue(at: next) { next = next.addingTimeInterval(1) }
            gaps.append(next.timeIntervalSince(now))
            now = next
        }
        XCTAssertEqual(gaps, [2, 4, 8, 16, 32, 60, 60, 60])
    }
}
