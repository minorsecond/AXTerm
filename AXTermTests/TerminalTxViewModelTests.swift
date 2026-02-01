//
//  TerminalTxViewModelTests.swift
//  AXTermTests
//
//  TDD tests for Terminal TX ViewModel.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10.5
//

import XCTest
@testable import AXTerm

final class TerminalTxViewModelTests: XCTestCase {

    // MARK: - Initial State Tests

    func testInitialState() {
        let vm = TerminalTxViewModel()

        XCTAssertTrue(vm.composeText.isEmpty)
        XCTAssertTrue(vm.destinationCall.isEmpty)
        XCTAssertTrue(vm.digiPath.isEmpty)
        XCTAssertTrue(vm.queueEntries.isEmpty)
        XCTAssertFalse(vm.canSend)
    }

    func testCanSendRequiresDestinationAndText() {
        var vm = TerminalTxViewModel()

        // No destination or text
        XCTAssertFalse(vm.canSend)

        // Only destination
        vm.destinationCall = "N0CALL"
        XCTAssertFalse(vm.canSend)

        // Only text
        vm.destinationCall = ""
        vm.composeText = "Hello"
        XCTAssertFalse(vm.canSend)

        // Both
        vm.destinationCall = "N0CALL"
        vm.composeText = "Hello"
        XCTAssertTrue(vm.canSend)
    }

    func testCanSendValidatesCallsign() {
        var vm = TerminalTxViewModel()
        vm.composeText = "Test message"

        // Invalid callsign (too short)
        vm.destinationCall = "A"
        XCTAssertFalse(vm.canSend)

        // Valid callsign
        vm.destinationCall = "N0CALL"
        XCTAssertTrue(vm.canSend)

        // Valid callsign with SSID
        vm.destinationCall = "N0CALL-1"
        XCTAssertTrue(vm.canSend)
    }

    // MARK: - Frame Building Tests

    func testBuildFrameCreatesUIFrame() {
        var vm = TerminalTxViewModel()
        vm.sourceCall = "MYCALL"
        vm.destinationCall = "N0CALL"
        vm.composeText = "Hello World"

        let frame = vm.buildOutboundFrame()

        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.source.call, "MYCALL")
        XCTAssertEqual(frame?.destination.call, "N0CALL")
        XCTAssertEqual(frame?.frameType, "ui")
        XCTAssertEqual(frame?.priority, .interactive)

        // Payload is AXDP-encoded, should start with magic header
        if let payload = frame?.payload {
            XCTAssertTrue(AXDP.hasMagic(payload), "Payload should have AXDP magic header")
            // Decode and verify the message
            if let msg = AXDP.Message.decode(from: payload) {
                XCTAssertEqual(msg.type, .chat)
                if let textData = msg.payload, let text = String(data: textData, encoding: .utf8) {
                    XCTAssertEqual(text, "Hello World")
                } else {
                    XCTFail("Message payload should contain the text")
                }
            } else {
                XCTFail("Payload should be valid AXDP message")
            }
        } else {
            XCTFail("Frame should have payload")
        }
    }

    func testBuildFrameWithDigiPath() {
        var vm = TerminalTxViewModel()
        vm.sourceCall = "MYCALL"
        vm.destinationCall = "N0CALL"
        vm.digiPath = "WIDE1-1,WIDE2-1"
        vm.composeText = "Test"

        let frame = vm.buildOutboundFrame()

        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.path.count, 2)
        XCTAssertEqual(frame?.path.digis[0].call, "WIDE1")
        XCTAssertEqual(frame?.path.digis[0].ssid, 1)
        XCTAssertEqual(frame?.path.digis[1].call, "WIDE2")
        XCTAssertEqual(frame?.path.digis[1].ssid, 1)
    }

    func testBuildFrameWithSSID() {
        var vm = TerminalTxViewModel()
        vm.sourceCall = "MYCALL-5"
        vm.destinationCall = "N0CALL-10"
        vm.composeText = "Test"

        let frame = vm.buildOutboundFrame()

        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.source.ssid, 5)
        XCTAssertEqual(frame?.destination.ssid, 10)
    }

    func testBuildFrameReturnsNilWhenInvalid() {
        var vm = TerminalTxViewModel()

        // No destination
        vm.sourceCall = "MYCALL"
        vm.composeText = "Test"
        XCTAssertNil(vm.buildOutboundFrame())

        // No text
        vm.destinationCall = "N0CALL"
        vm.composeText = ""
        XCTAssertNil(vm.buildOutboundFrame())
    }

    // MARK: - Queue Management Tests

    func testEnqueueAddsToQueue() {
        var vm = TerminalTxViewModel()
        vm.sourceCall = "MYCALL"
        vm.destinationCall = "N0CALL"
        vm.composeText = "Test message"

        let frameId = vm.enqueueCurrentMessage()

        XCTAssertNotNil(frameId)
        XCTAssertEqual(vm.queueEntries.count, 1)
        XCTAssertEqual(vm.queueEntries.first?.frame.id, frameId)
    }

    func testEnqueueClearsComposeText() {
        var vm = TerminalTxViewModel()
        vm.sourceCall = "MYCALL"
        vm.destinationCall = "N0CALL"
        vm.composeText = "Test message"

        _ = vm.enqueueCurrentMessage()

        XCTAssertTrue(vm.composeText.isEmpty)
    }

    func testEnqueuePreservesDestination() {
        var vm = TerminalTxViewModel()
        vm.sourceCall = "MYCALL"
        vm.destinationCall = "N0CALL"
        vm.digiPath = "WIDE1-1"
        vm.composeText = "Test"

        _ = vm.enqueueCurrentMessage()

        // Destination and path should remain for easy follow-up
        XCTAssertEqual(vm.destinationCall, "N0CALL")
        XCTAssertEqual(vm.digiPath, "WIDE1-1")
    }

    func testCancelFrameRemovesFromQueue() {
        var vm = TerminalTxViewModel()
        vm.sourceCall = "MYCALL"
        vm.destinationCall = "N0CALL"
        vm.composeText = "Test"

        let frameId = vm.enqueueCurrentMessage()!

        XCTAssertEqual(vm.queueEntries.count, 1)

        vm.cancelFrame(frameId)

        // Should be marked cancelled, not removed (for history)
        XCTAssertEqual(vm.queueEntries.first?.state.status, .cancelled)
    }

    // MARK: - History Tests

    func testMessageHistoryTracksRecentDestinations() {
        var vm = TerminalTxViewModel()
        vm.sourceCall = "MYCALL"

        // Send to multiple destinations
        vm.destinationCall = "CALL1"
        vm.composeText = "Test 1"
        _ = vm.enqueueCurrentMessage()

        vm.destinationCall = "CALL2"
        vm.composeText = "Test 2"
        _ = vm.enqueueCurrentMessage()

        vm.destinationCall = "CALL1"
        vm.composeText = "Test 3"
        _ = vm.enqueueCurrentMessage()

        // Recent destinations should be unique and ordered by recency
        let recent = vm.recentDestinations
        XCTAssertEqual(recent.first, "CALL1")  // Most recent
        XCTAssertTrue(recent.contains("CALL2"))
    }

    // MARK: - Character Count Tests

    func testCharacterCountUpdates() {
        var vm = TerminalTxViewModel()

        vm.composeText = "Hello"
        XCTAssertEqual(vm.characterCount, 5)

        vm.composeText = "Hello World"
        XCTAssertEqual(vm.characterCount, 11)
    }

    func testPayloadSizeEstimate() {
        var vm = TerminalTxViewModel()
        vm.composeText = "Test message"

        // Payload size should account for AXDP overhead
        let size = vm.estimatedPayloadSize
        XCTAssertGreaterThan(size, vm.composeText.utf8.count)
    }
}
