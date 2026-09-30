import XCTest
import Combine
@testable import AXTerm

/// The toolbar chip and the map read the station position through the
/// context, so a change in the location service has to reach the
/// context's observers. It didn't: Settings showed the device location in
/// use while the chip and the map said "No position".
@MainActor
final class WinlinkContextLocationTests: XCTestCase {

    func testLocationServiceChangesReachContextObservers() {
        let context = WinlinkContext(store: nil, settings: WinlinkSettings())
        var notified = 0
        let subscription = context.objectWillChange.sink { _ in notified += 1 }
        defer { subscription.cancel() }

        context.locationService.objectWillChange.send()

        XCTAssertEqual(notified, 1)
    }
}
