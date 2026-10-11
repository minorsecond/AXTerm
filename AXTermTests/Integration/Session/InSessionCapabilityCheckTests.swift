//
//  InSessionCapabilityCheckTests.swift
//  AXTermTests
//
//  Constitution retest 2026-10-11, findings 1 and 5. The iPad connected to
//  the K0EPI-4 mailbox, whose greeting says AXTerm, and sent the one UI
//  probe. A answered within 0.1 s, and the answer went out on top of the
//  iPad's RR for the greeting, sent 2.2 s later on its delayed-ack timer.
//  UI frames are never resent, so the iPad marked the mailbox "not AXDP"
//  for a day and Send File showed no area picker.
//
//  Now a station with an AXTerm sign is asked inside the connection, where
//  AX.25 resends what is lost and the acknowledgment rides in each frame's
//  header. Every other station gets one UI probe, sent in the same
//  transmission as the RR, and the answer is kept a month either way. A
//  station remembered as AXTerm starts confirmed with nothing sent.
//

import XCTest
@testable import AXTerm

@MainActor
final class InSessionCapabilityCheckTests: XCTestCase {

    private var caller: TransferStation!
    private var answerer: TransferStation!
    /// Capability frames handed to either radio: who, what, and how.
    private var frames: [(station: String, info: String, type: String)] = []
    /// Every frame the caller hands to its radio, in order, with the time.
    private var callerFrames: [(frame: OutboundFrame, at: Date)] = []

    private static let capabilityFrames: Set<String> = ["AXDP probe", "AXDP PING", "AXDP PONG"]

    override func setUp() async throws {
        caller = TransferStation(callsign: "K0AAA-1")
        answerer = TransferStation(callsign: "K0BBB-2")
        for station in [caller!, answerer!] {
            station.coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
            station.coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
            station.coordinator.peerMemory = AXDPPeerMemory(defaults: TestDefaults.make("InSession-\(station.callsign)"))
            let name = station.callsign
            station.coordinator.onFrameHandedToRadio = { [weak self] frame in
                if let info = frame.displayInfo, Self.capabilityFrames.contains(info) {
                    self?.frames.append((name, info, frame.frameType))
                }
                if name == "K0AAA-1" { self?.callerFrames.append((frame, Date())) }
            }
        }
        // Neither side's fallback fires unless a test wants it.
        caller.coordinator.testTextProbeFallbackDelay = 60
        answerer.coordinator.testTextProbeFallbackDelay = 60
    }

    override func tearDown() async throws {
        caller?.tearDown()
        answerer?.tearDown()
        try? await Task.sleep(nanoseconds: 50_000_000)
        caller = nil
        answerer = nil
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func connect() async throws {
        caller.connectLink(to: answerer)
        answerer.connectLink(to: caller)
        if let sabm = caller.coordinator.sessionManager.connect(
            to: answerer.address, path: DigiPath(), radio: caller.coordinator.primaryRadioID) {
            caller.coordinator.sendFrame(sabm)
        }
        try await waitUntil("the link comes up") { self.caller.session != nil && self.answerer.session != nil }
    }

    /// The answering station sends its greeting, as a mailbox does.
    private func greet(_ text: String) {
        for frame in answerer.coordinator.sessionManager.sendData(
            Data(text.utf8), to: caller.address, path: DigiPath(), radio: answerer.coordinator.primaryRadioID) {
            answerer.coordinator.sendFrame(frame)
        }
    }

    private func bothKnowEachOther() -> Bool {
        caller.coordinator.capabilityStatus(for: answerer.address.display) == .confirmed
            && answerer.coordinator.capabilityStatus(for: caller.address.display) == .confirmed
    }

    /// The message-type field, which follows the magic and the length.
    private static func marker(_ type: AXDP.MessageType) -> Data {
        AXDP.TLV(type: AXDP.TLVType.messageType.rawValue, value: Data([type.rawValue])).encode()
    }

    // MARK: - A station with a sign

    func testAStationThatSaysAXTermIsAskedInsideTheConnection() async throws {
        try await connect()
        greet("AXTerm personal mailbox - K0BBB-2\r")
        try await waitUntil("both know the other", bothKnowEachOther)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(frames.contains { $0.type == "ui" }, "no UI frames: \(frames)")
        XCTAssertTrue(frames.contains { $0.station == "K0AAA-1" && $0.info == "AXDP PING" && $0.type == "i" })
        XCTAssertTrue(frames.contains { $0.station == "K0BBB-2" && $0.info == "AXDP PONG" && $0.type == "i" })
        XCTAssertEqual(caller.coordinator.peerMemory.capabilities(for: answerer.address.display),
                       AXDPCapability.defaultLocal(), "kept for next time")
    }

    /// The bug from the run: the answer is lost on the air. Inside the
    /// connection AX.25 sends it again.
    func testALostAnswerIsSentAgain() async throws {
        answerer.link.losesNextFrameContaining = Self.marker(.pong)
        try await connect()
        greet("AXTerm personal mailbox - K0BBB-2\r")
        try await waitUntil("both know the other", bothKnowEachOther)
        XCTAssertNil(answerer.link.losesNextFrameContaining, "the answer was lost once")
        XCTAssertNotEqual(caller.coordinator.peerMemory.verdict(for: answerer.address.display), .notAXDP)
    }

    func testAStationRememberedAsNotAXTermIsAskedWhenItSaysItIs() async throws {
        caller.coordinator.peerMemory.record(.notAXDP, for: answerer.address.display)
        try await connect()
        greet("AXTerm personal mailbox - K0BBB-2\r")
        try await waitUntil("both know the other", bothKnowEachOther)
        XCTAssertEqual(caller.coordinator.peerMemory.verdict(for: answerer.address.display), .axterm)
    }

    /// Known with its capabilities: confirmed at once, nothing sent.
    func testARememberedStationStartsConfirmedWithNothingSent() async throws {
        caller.coordinator.peerMemory.record(.axterm, for: answerer.address.display,
                                             capabilities: AXDPCapability.defaultLocal())
        try await connect()
        XCTAssertEqual(caller.coordinator.capabilityStatus(for: answerer.address.display), .confirmed)
        greet("AXTerm personal mailbox - K0BBB-2\r")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(frames.contains { $0.station == "K0AAA-1" }, "\(frames)")
    }

    // MARK: - A station with no sign

    /// One UI probe, and the RR for the greeting goes with it, so the
    /// answer comes back to a quiet channel.
    func testAStationWithNoSignGetsOneProbeWithTheAcknowledgment() async throws {
        try await connect()
        greet("Welcome\r")
        try await waitUntil("both know the other", bothKnowEachOther)

        let probe = try XCTUnwrap(callerFrames.firstIndex { $0.frame.displayInfo == "AXDP probe" })
        XCTAssertEqual(callerFrames[probe].frame.frameType, "ui")
        XCTAssertGreaterThan(probe, 0)
        let before = callerFrames[probe - 1]
        XCTAssertEqual(before.frame.frameType, "s", "the RR goes just ahead of the probe")
        XCTAssertLessThan(callerFrames[probe].at.timeIntervalSince(before.at), 0.02, "in one transmission")
        XCTAssertEqual(frames.filter { $0.info == "AXDP probe" }.count, 1)
    }

    /// The station that was called checks a caller that says nothing, once
    /// the fallback runs out (finding 1: either side).
    func testTheAnsweringStationChecksACallerThatSaysNothing() async throws {
        answerer.coordinator.testTextProbeFallbackDelay = 0.2
        try await connect()
        try await waitUntil("both know the other", bothKnowEachOther)
        XCTAssertTrue(frames.contains { $0.station == "K0BBB-2" && $0.info == "AXDP probe" }, "\(frames)")
    }
}
