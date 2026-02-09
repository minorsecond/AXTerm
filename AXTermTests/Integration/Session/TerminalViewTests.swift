//
//  TerminalViewTests.swift
//  AXTermTests
//
//  Tests for terminal view and observable view model.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10
//

import XCTest
import SwiftUI
@testable import AXTerm

final class TerminalViewTests: XCTestCase {

    @MainActor
    private func createViewModel(sourceCall: String = "N0CALL") -> ObservableTerminalTxViewModel {
        let settings = AppSettingsStore()
        let client = PacketEngine(settings: settings)
        let sessionManager = AX25SessionManager()
        let vm = ObservableTerminalTxViewModel(
            sourceCall: sourceCall,
            sessionManager: sessionManager
        )
        vm.configure(client: client, settings: settings)
        return vm
    }

    // MARK: - Observable ViewModel Tests

    func testObservableViewModelInitialization() async {
        await MainActor.run {
            let viewModel = createViewModel(sourceCall: "N0CALL")

            XCTAssertEqual(viewModel.sourceCall, "N0CALL")
            XCTAssertTrue(viewModel.composeText.wrappedValue.isEmpty)
            XCTAssertTrue(viewModel.destinationCall.wrappedValue.isEmpty)
        }
    }

    func testObservableViewModelComposeBinding() async {
        await MainActor.run {
            let viewModel = createViewModel(sourceCall: "N0CALL")

            viewModel.composeText.wrappedValue = "Hello World"

            XCTAssertEqual(viewModel.composeText.wrappedValue, "Hello World")
            XCTAssertEqual(viewModel.characterCount, 11)
        }
    }

    func testObservableViewModelDestinationBinding() async {
        await MainActor.run {
            let viewModel = createViewModel(sourceCall: "N0CALL")

            viewModel.destinationCall.wrappedValue = "K0ABC"

            XCTAssertEqual(viewModel.destinationCall.wrappedValue, "K0ABC")
        }
    }

    func testObservableViewModelDigiPathBinding() async {
        await MainActor.run {
            let viewModel = createViewModel(sourceCall: "N0CALL")

            viewModel.digiPath.wrappedValue = "WIDE1-1"

            XCTAssertEqual(viewModel.digiPath.wrappedValue, "WIDE1-1")
        }
    }

    func testObservableViewModelCanSendRequiresText() async {
        await MainActor.run {
            let viewModel = createViewModel(sourceCall: "N0CALL")

            // Initially cannot send (no text)
            XCTAssertFalse(viewModel.canSend)

            // Add text only - CAN send (broadcast to CQ)
            viewModel.composeText.wrappedValue = "Test"
            XCTAssertTrue(viewModel.canSend, "Should allow broadcast with empty destination")

            // Add destination - still can send
            viewModel.destinationCall.wrappedValue = "K0ABC"
            XCTAssertTrue(viewModel.canSend)
        }
    }

    func testObservableViewModelUpdateSourceCall() async {
        await MainActor.run {
            let viewModel = createViewModel(sourceCall: "N0CALL")

            viewModel.updateSourceCall("K0NEW")

            XCTAssertEqual(viewModel.sourceCall, "K0NEW")
        }
    }

    func testObservableViewModelClearCompose() async {
        await MainActor.run {
            let viewModel = createViewModel(sourceCall: "N0CALL")
            viewModel.composeText.wrappedValue = "Some text"

            viewModel.clearCompose()

            XCTAssertTrue(viewModel.composeText.wrappedValue.isEmpty)
        }
    }

    func testObservableViewModelQueueDepthInitiallyZero() async {
        await MainActor.run {
            let viewModel = createViewModel(sourceCall: "N0CALL")

            XCTAssertEqual(viewModel.queueDepth, 0)
            XCTAssertTrue(viewModel.queueEntries.isEmpty)
        }
    }

    func testObservableViewModelEnqueueMessage() async {
        await MainActor.run {
            let viewModel = createViewModel(sourceCall: "N0CALL")
            viewModel.composeText.wrappedValue = "Test message"
            viewModel.destinationCall.wrappedValue = "K0ABC"

            viewModel.enqueueCurrentMessage()

            // Compose text should be cleared after enqueue
            XCTAssertTrue(viewModel.composeText.wrappedValue.isEmpty)
            // Queue should have entry
            XCTAssertEqual(viewModel.queueEntries.count, 1)
        }
    }

    // MARK: - Terminal Tab Enum Tests

    func testTerminalTabAllCases() {
        let allCases = TerminalTab.allCases

        XCTAssertEqual(allCases.count, 2)
        XCTAssertTrue(allCases.contains(.session))
        XCTAssertTrue(allCases.contains(.transfers))
    }

    func testTerminalTabRawValues() {
        XCTAssertEqual(TerminalTab.session.rawValue, "Session")
        XCTAssertEqual(TerminalTab.transfers.rawValue, "Transfers")
    }

    // MARK: - Navigation Item Tests

    func testNavigationItemIncludesTerminal() {
        let allCases = NavigationItem.allCases

        XCTAssertTrue(allCases.contains(.terminal))
    }

    func testNavigationItemTerminalRawValue() {
        XCTAssertEqual(NavigationItem.terminal.rawValue, "Terminal")
    }

    func testNavigationItemTerminalIsFirstItem() {
        let allCases = NavigationItem.allCases

        // Terminal should be first in the list (the default view)
        XCTAssertEqual(allCases[0], .terminal)
        XCTAssertEqual(allCases[1], .packets)
    }
}
