import XCTest
@testable import AXTerm

final class CoalescingSchedulerTests: XCTestCase {
    @MainActor
    func testCoalescingSchedulerRunsLatestOnly() async {
        let scheduler = CoalescingScheduler(delay: .milliseconds(40))
        let expectation = expectation(description: "scheduler fires once")
        expectation.expectedFulfillmentCount = 1
        let counter = Counter()

        scheduler.schedule {
            await counter.increment()
            expectation.fulfill()
        }
        scheduler.schedule {
            await counter.increment()
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1.0)
        let value = await counter.value
        XCTAssertEqual(value, 1)
    }

    @MainActor
    func testSchedulerCanBeDroppedImmediatelyAfterScheduling() async {
        var scheduler: CoalescingScheduler? = CoalescingScheduler(delay: .milliseconds(10))
        scheduler?.schedule {
            await Task.yield()
        }
        scheduler = nil

        // Wait long enough to ensure any pending task would have run if it had
        // survived the deallocation; there should be no crash.
        try? await Task.sleep(for: .milliseconds(50))
    }
}

private actor Counter {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }
}
