//
//  WinlinkSyncDefaultTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

@MainActor
final class WinlinkSyncDefaultTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SyncDefault-\(UUID().uuidString)")!
    }

    private func settings(_ defaults: UserDefaults) -> WinlinkSettings {
        WinlinkSettings(defaults: defaults,
                        keychain: KeychainStore(service: "test-\(UUID().uuidString)"))
    }

    func testANewStationSyncsItsMailboxByDefault() async throws {
        let vm = settings(freshDefaults())
        XCTAssertTrue(vm.mailboxSyncEnabled,
                      "Mail is what an operator expects on whichever device they pick up")
    }

    func testAnOperatorWhoTurnedItOffKeepsItOff() async throws {
        let defaults = freshDefaults()
        defaults.set(false, forKey: WinlinkSettings.mailboxSyncEnabledKey)

        let vm = settings(defaults)

        // The default must apply only where no decision exists. Re-enabling
        // sync under someone who switched it off would put their mail on
        // Apple's servers against an explicit choice.
        XCTAssertFalse(vm.mailboxSyncEnabled)
    }

    func testAnExplicitOnIsAlsoHonoured() async throws {
        let defaults = freshDefaults()
        defaults.set(true, forKey: WinlinkSettings.mailboxSyncEnabledKey)
        XCTAssertTrue(settings(defaults).mailboxSyncEnabled)
    }

    func testTurningItOffPersists() async throws {
        let defaults = freshDefaults()
        let vm = settings(defaults)
        vm.mailboxSyncEnabled = false
        XCTAssertFalse(settings(defaults).mailboxSyncEnabled)
    }

    // MARK: - The address book is part of the deal

    func testContactsAreDeclaredSyncable() async throws {
        guard case .synced = WinlinkSyncPolicy.disposition(for: .contact) else {
            return XCTFail("contacts must be declared syncable for the engine to push them")
        }
    }

    func testMeasurementsStillNeverTravel() async throws {
        // Turning sync on by default must not quietly widen what leaves the
        // device. These describe this radio at this place.
        for kind in [WinlinkSyncPolicy.Kind.gatewayLadder,
                     .sessionLog, .gridSquare, .callsignSSID] {
            if case .synced = WinlinkSyncPolicy.disposition(for: kind) {
                XCTFail("\(kind) must not replicate — it describes this station, not the operator")
            }
        }
    }
}
