import XCTest
@testable import AXTerm

final class CoalescingSchedulerTests: XCTestCase {
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
}

private actor Counter {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }
}
