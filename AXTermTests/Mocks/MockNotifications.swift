//
//  MockNotifications.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/4/26.
//

import Foundation
import UserNotifications
@testable import AXTerm

final class MockNotificationScheduler: NotificationScheduling {
    private(set) var scheduledPackets: [Packet] = []
    private(set) var scheduledMatches: [WatchMatch] = []

    func scheduleWatchNotification(packet: Packet, match: WatchMatch) {
        scheduledPackets.append(packet)
        scheduledMatches.append(match)
    }
}

final class MockNotificationCenter: NotificationCenterScheduling {
    private(set) var requests: [UNNotificationRequest] = []

    func add(_ request: UNNotificationRequest) {
        requests.append(request)
    }
}

struct MockAppState: AppStateProviding {
    var isFrontmost: Bool
}
