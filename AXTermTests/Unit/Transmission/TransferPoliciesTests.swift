//
//  TransferPoliciesTests.swift
//  AXTermTests
//
//  The decisions behind packet file transfer, each on its own: which
//  protocol sends, how offers are judged, when a quiet transfer is given up
//  on, what a dropped link says, what starts a YAPP receive, when the
//  operator gets a notification, and the words each device shows.
//

import XCTest
import UniformTypeIdentifiers
import UserNotifications
@testable import AXTerm

@MainActor
final class TransferPoliciesTests: XCTestCase {

    // MARK: - Protocol dispatch

    func testEachProtocolRoutesToItsOwnSender() {
        XCTAssertEqual(TransferSendRoute.route(for: .axdp), .axdp)
        XCTAssertEqual(TransferSendRoute.route(for: .yapp), .yapp)
    }

    func testProtocolsWithNoSenderAreRefusedNotSwapped() {
        guard case .unavailable(let seven) = TransferSendRoute.route(for: .sevenPlus),
              case .unavailable(let raw) = TransferSendRoute.route(for: .rawBinary) else {
            return XCTFail("7plus and raw binary have no sender")
        }
        XCTAssertTrue(seven.contains("7plus"))
        XCTAssertTrue(raw.contains("Raw Binary"))
    }

    func testTheYAPPSuggestionOnlyAppearsWhenYAPPWorks() {
        let usable = TransferSendRoute.axdpUnsupportedMessage(destination: "N0CALL", yappAvailable: true)
        XCTAssertTrue(usable.contains("Choose YAPP instead"))
        let unusable = TransferSendRoute.axdpUnsupportedMessage(destination: "N0CALL", yappAvailable: false)
        XCTAssertFalse(unusable.contains("Choose YAPP"))
        XCTAssertTrue(unusable.contains("Connect to N0CALL first"))
        XCTAssertFalse(unusable.contains("legacy"))
    }

    /// The registry only offers what can be sent: YAPP needs a connected
    /// session, AXDP a confirmed peer, 7plus and raw binary never.
    func testTheRegistryOffersOnlySendableProtocols() {
        let registry = TransferProtocolRegistry.shared
        XCTAssertEqual(registry.availableProtocols(for: "X", hasAXDP: true, isConnected: true), [.axdp, .yapp])
        XCTAssertEqual(registry.availableProtocols(for: "X", hasAXDP: false, isConnected: true), [.yapp])
        XCTAssertEqual(registry.availableProtocols(for: "X", hasAXDP: true, isConnected: false), [.axdp])
        XCTAssertEqual(registry.availableProtocols(for: "X", hasAXDP: false, isConnected: false), [])
        for available in [registry.availableProtocols(for: "X", hasAXDP: true, isConnected: true)] {
            for type in available {
                if case .unavailable = TransferSendRoute.route(for: type) {
                    XCTFail("\(type) is offered but cannot be sent")
                }
            }
        }
    }

    // MARK: - Offers

    private func policy(allowed: [String] = [], denied: [String] = [], cap: Int = 1_000) -> TransferOfferPolicy {
        TransferOfferPolicy(allowed: allowed, denied: denied, maxBytes: cap)
    }

    func testAnUnknownStationIsAskedAbout() {
        XCTAssertEqual(policy().decide(callsign: "N0CALL", fileSize: 10), .ask)
    }

    func testTheAllowListAccepts() {
        guard case .accept(let reason) = policy(allowed: ["n0call"]).decide(callsign: "N0CALL", fileSize: 10) else {
            return XCTFail("allow list accepts, whatever the case")
        }
        XCTAssertTrue(reason.contains("allow list"))
    }

    func testTheDenyListDeclines() {
        guard case .decline(let reason) = policy(denied: ["N0CALL"]).decide(callsign: "n0call", fileSize: 10) else {
            return XCTFail("deny list declines")
        }
        XCTAssertTrue(reason.contains("deny list"))
    }

    func testTheDenyListBeatsTheAllowList() {
        let both = policy(allowed: ["N0CALL"], denied: ["N0CALL"])
        guard case .decline = both.decide(callsign: "N0CALL", fileSize: 10) else { return XCTFail() }
    }

    func testTheCapDeclinesEvenTrustedStations() {
        guard case .decline(let reason) = policy(allowed: ["N0CALL"], cap: 100)
            .decide(callsign: "N0CALL", fileSize: 101) else {
            return XCTFail("over the cap is declined")
        }
        XCTAssertTrue(reason.contains("limit"))
        XCTAssertEqual(policy(cap: 100).decide(callsign: "X", fileSize: 100), .ask, "at the cap is fine")
    }

    func testACapOfZeroMeansNoCap() {
        XCTAssertEqual(policy(cap: 0).decide(callsign: "X", fileSize: 50_000_000), .ask)
    }

    func testTheDefaultCapIsOneMegabyte() {
        XCTAssertEqual(TransferOfferPolicy.defaultMaxBytes, 1_048_576)
        XCTAssertEqual(AppSettingsStore.defaultMaxIncomingTransferBytes, TransferOfferPolicy.defaultMaxBytes)
    }

    func testSettingsHandTheirListsAndCapToThePolicy() {
        let settings = AppSettingsStore(defaults: TestDefaults.make("TransferPolicySettings"))
        settings.allowCallsignForFileTransfer("K1ABC")
        settings.denyCallsignForFileTransfer("K2XYZ")
        settings.maxIncomingTransferBytes = 2048
        let policy = settings.fileTransferOfferPolicy
        XCTAssertEqual(policy.allowed, ["K1ABC"])
        XCTAssertEqual(policy.denied, ["K2XYZ"])
        XCTAssertEqual(policy.maxBytes, 2048)
        settings.maxIncomingTransferBytes = -5
        XCTAssertEqual(settings.maxIncomingTransferBytes, 0, "a negative cap is no cap")
    }

    // MARK: - Airtime

    func testAirtimeNeedsAMeasuredRate() {
        XCTAssertNil(TransferAirtimeEstimate.seconds(bytes: 1000, bytesPerSecond: nil))
        XCTAssertNil(TransferAirtimeEstimate.seconds(bytes: 1000, bytesPerSecond: 0))
        XCTAssertEqual(TransferAirtimeEstimate.seconds(bytes: 1000, bytesPerSecond: 50), 20)
    }

    func testAirtimeReadsLikeAPerson() {
        XCTAssertEqual(TransferAirtimeEstimate.describe(20), "under a minute")
        XCTAssertEqual(TransferAirtimeEstimate.describe(60), "about 1 minute")
        XCTAssertEqual(TransferAirtimeEstimate.describe(720), "about 12 minutes")
        XCTAssertEqual(TransferAirtimeEstimate.describe(3600), "about 1 hour")
        XCTAssertEqual(TransferAirtimeEstimate.describe(7500), "about 2 hours 5 minutes")
    }

    // MARK: - Watchdog

    private let quick = TransferTimeouts(awaitingAcceptance: 10, offerExpiry: 9, outboundStall: 8,
                                         awaitingCompletion: 7, inboundStall: 6)

    func testEachWaitHasItsOwnLimit() {
        XCTAssertNil(TransferWatchdog.verdict(status: .awaitingAcceptance, direction: .outbound, idle: 9.9, peer: "P", timeouts: quick))
        XCTAssertNotNil(TransferWatchdog.verdict(status: .awaitingAcceptance, direction: .outbound, idle: 10, peer: "P", timeouts: quick))
        XCTAssertNotNil(TransferWatchdog.verdict(status: .pending, direction: .inbound, idle: 9, peer: "P", timeouts: quick))
        XCTAssertNotNil(TransferWatchdog.verdict(status: .sending, direction: .outbound, idle: 8, peer: "P", timeouts: quick))
        XCTAssertNotNil(TransferWatchdog.verdict(status: .awaitingCompletion, direction: .outbound, idle: 7, peer: "P", timeouts: quick))
        XCTAssertNotNil(TransferWatchdog.verdict(status: .sending, direction: .inbound, idle: 6, peer: "P", timeouts: quick))
        XCTAssertNil(TransferWatchdog.verdict(status: .sending, direction: .inbound, idle: 5.9, peer: "P", timeouts: quick))
    }

    func testPausedAndFinishedTransfersAreNeverTimedOut() {
        for status in [BulkTransferStatus.paused, .completed, .cancelled, .failed(reason: "x")] {
            XCTAssertNil(TransferWatchdog.verdict(status: status, direction: .outbound, idle: 1e9, peer: "P", timeouts: quick))
        }
    }

    func testTheReceiverNeverAcceptsWhatTheSenderGaveUpOn() {
        let standard = TransferTimeouts.standard
        XCTAssertLessThan(standard.offerExpiry, standard.awaitingAcceptance)
    }

    func testTimeoutReasonsNameThePeer() {
        let reason = TransferWatchdog.verdict(status: .awaitingCompletion, direction: .outbound, idle: 999,
                                              peer: "N0CALL", timeouts: quick)
        XCTAssertEqual(reason, "N0CALL stopped answering before confirming the file arrived.")
    }

    // MARK: - Link loss

    func testLinkLossSaysWhatHappened() {
        XCTAssertEqual(TransferLinkLoss.reason(peer: "N0CALL", timedOut: true),
                       "The link to N0CALL was lost: it stopped answering.")
        XCTAssertEqual(TransferLinkLoss.reason(peer: "N0CALL", timedOut: false),
                       "The link to N0CALL closed before the transfer finished.")
    }

    // MARK: - YAPP detection

    func testOnlyAnExactSIPacketStartsAReceive() {
        XCTAssertTrue(YAPPReceiveDetector.shouldStart(packet: Data([0x05, 0x01]), activeTransfersWithPeer: 0))
    }

    func testSIInsideTextIsJustText() {
        let text = Data("Downloading \u{05}\u{01} now\r".utf8)
        XCTAssertFalse(YAPPReceiveDetector.shouldStart(packet: text, activeTransfersWithPeer: 0))
        XCTAssertFalse(YAPPReceiveDetector.shouldStart(packet: Data([0x05, 0x01, 0x0D]), activeTransfersWithPeer: 0))
        XCTAssertFalse(YAPPReceiveDetector.shouldStart(packet: Data([0x0D, 0x05, 0x01]), activeTransfersWithPeer: 0))
        XCTAssertFalse(YAPPReceiveDetector.shouldStart(packet: Data([0x05]), activeTransfersWithPeer: 0))
        XCTAssertFalse(YAPPReceiveDetector.shouldStart(packet: Data([0x01, 0x01]), activeTransfersWithPeer: 0))
    }

    func testNoReceiveStartsWhileAnotherTransferRuns() {
        XCTAssertFalse(YAPPReceiveDetector.shouldStart(packet: Data([0x05, 0x01]), activeTransfersWithPeer: 1))
    }

    // MARK: - Notifications

    private let offer = TransferNotificationEvent.offer(from: "N0CALL", fileName: "A.TXT", fileSize: 2048)
    private let done = TransferNotificationEvent.completed(fileName: "A.TXT", peer: "N0CALL", direction: .inbound)

    func testOffersNotifyOnlyInTheBackground() {
        XCTAssertTrue(TransferNotificationPolicy.shouldNotify(offer, enabled: true, onlyWhenInactive: false, isFrontmost: false))
        XCTAssertFalse(TransferNotificationPolicy.shouldNotify(offer, enabled: true, onlyWhenInactive: false, isFrontmost: true),
                       "in front, the prompt is already on screen")
    }

    func testResultsFollowTheOnlyWhenInactiveSetting() {
        XCTAssertTrue(TransferNotificationPolicy.shouldNotify(done, enabled: true, onlyWhenInactive: false, isFrontmost: true))
        XCTAssertFalse(TransferNotificationPolicy.shouldNotify(done, enabled: true, onlyWhenInactive: true, isFrontmost: true))
        XCTAssertTrue(TransferNotificationPolicy.shouldNotify(done, enabled: true, onlyWhenInactive: true, isFrontmost: false))
        let failed = TransferNotificationEvent.failed(fileName: "A", peer: "P", reason: "r")
        XCTAssertTrue(TransferNotificationPolicy.shouldNotify(failed, enabled: true, onlyWhenInactive: true, isFrontmost: false))
    }

    func testTurningTransferNotificationsOffSilencesThemAll() {
        for event in [offer, done, .failed(fileName: "A", peer: "P", reason: "r"), .canceledByPeer(fileName: "A", peer: "P")] {
            XCTAssertFalse(TransferNotificationPolicy.shouldNotify(event, enabled: false, onlyWhenInactive: false, isFrontmost: false))
        }
    }

    func testNotificationTextSaysWhatAndWhere() {
        let offerText = TransferNotificationPolicy.content(for: offer)
        XCTAssertEqual(offerText.title, "N0CALL wants to send you a file")
        XCTAssertTrue(offerText.body.hasPrefix("A.TXT (2 KB)"))
        let doneText = TransferNotificationPolicy.content(for: done)
        XCTAssertEqual(doneText.body, "A.TXT is in AXTerm Transfers.")
        let sent = TransferNotificationPolicy.content(for: .completed(fileName: "B", peer: "P", direction: .outbound))
        XCTAssertEqual(sent.title, "File sent to P")
        let failed = TransferNotificationPolicy.content(for: .failed(fileName: "C", peer: "P", reason: "No answer."))
        XCTAssertEqual(failed.body, "C: No answer.")
    }

    func testTheUserNotificationSchedulerAppliesThePolicy() {
        let center = MockNotificationCenter()
        let defaults = TestDefaults.make("TransferNotifications")
        let settings = AppSettingsStore(defaults: defaults)
        settings.notifyOnFileTransfers = true
        settings.notifyOnlyWhenInactive = true
        let background = UserNotificationScheduler(center: center, settings: settings, appState: MockAppState(isFrontmost: false))
        background.scheduleTransferNotification(offer)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.content.title, "N0CALL wants to send you a file")

        let front = UserNotificationScheduler(center: center, settings: settings, appState: MockAppState(isFrontmost: true))
        front.scheduleTransferNotification(offer)
        front.scheduleTransferNotification(done)
        XCTAssertEqual(center.requests.count, 1, "in front with only-when-inactive on, nothing more")

        settings.notifyOnFileTransfers = false
        background.scheduleTransferNotification(done)
        XCTAssertEqual(center.requests.count, 1)
    }

    // MARK: - Prompt queue

    private func request(_ name: String) -> IncomingTransferRequest {
        IncomingTransferRequest(sourceCallsign: "N0CALL", fileName: name, fileSize: 1, axdpSessionId: 1)
    }

    func testThePromptKeepsTheOfferItIsShowing() {
        let a = request("a"), b = request("b")
        XCTAssertEqual(IncomingTransferPromptQueue.next(pending: [a, b], showing: b)?.id, b.id)
    }

    func testThePromptMovesOnWhenAnOfferIsAnsweredElsewhere() {
        let a = request("a"), b = request("b")
        XCTAssertEqual(IncomingTransferPromptQueue.next(pending: [b], showing: a)?.id, b.id)
        XCTAssertNil(IncomingTransferPromptQueue.next(pending: [], showing: a))
        XCTAssertEqual(IncomingTransferPromptQueue.next(pending: [a, b], showing: nil)?.id, a.id)
    }

    // MARK: - Words per device

    func testNoDeviceIsToldToDoWhatItCannot() {
        XCTAssertFalse(TransferCopy.emptyStateHint(for: .iPhone).localizedCaseInsensitiveContains("drag"))
        XCTAssertFalse(TransferCopy.emptyStateHint(for: .iPhone).localizedCaseInsensitiveContains("click"))
        XCTAssertFalse(TransferCopy.emptyStateHint(for: .iPad).localizedCaseInsensitiveContains("click"))
        XCTAssertTrue(TransferCopy.emptyStateHint(for: .iPad).contains("Drop"))
        XCTAssertTrue(TransferCopy.emptyStateHint(for: .mac).contains("click"))
    }

    func testThePromptNamesTheFolder() {
        XCTAssertTrue(TransferCopy.saveLocation(for: .mac).contains("Downloads › AXTerm Transfers"))
        XCTAssertTrue(TransferCopy.saveLocation(for: .iPhone).contains("Files app"))
        XCTAssertTrue(TransferCopy.saveLocation(for: .iPad).contains("AXTerm Transfers"))
    }

    func testTheOfferSummaryQuotesAirtimeOnlyWhenKnown() {
        let unknown = IncomingTransferRequest(sourceCallsign: "N0CALL", fileName: "A", fileSize: 2048,
                                              axdpSessionId: 1, transferProtocol: .yapp)
        XCTAssertEqual(TransferCopy.offerSummary(unknown), "2 KB by YAPP.")
        let known = IncomingTransferRequest(sourceCallsign: "N0CALL", fileName: "A", fileSize: 2048,
                                            axdpSessionId: 1, estimatedAirtimeSeconds: 180)
        XCTAssertEqual(TransferCopy.offerSummary(known),
                       "2 KB by AXDP, about 3 minutes of airtime at the rate of your last transfer with N0CALL.")
    }

    // MARK: - Drops

    func testFilesAreAcceptedAndDraggedTextIsNot() {
        XCTAssertTrue(TransferDropFilter.isFile(typeIdentifiers: [UTType.fileURL.identifier], suggestedName: nil))
        XCTAssertTrue(TransferDropFilter.isFile(typeIdentifiers: [UTType.jpeg.identifier], suggestedName: "IMG_1"))
        XCTAssertTrue(TransferDropFilter.isFile(typeIdentifiers: [UTType.pdf.identifier], suggestedName: nil),
                      "unnamed binary data is still a file")
        XCTAssertTrue(TransferDropFilter.isFile(typeIdentifiers: [UTType.plainText.identifier], suggestedName: "notes"),
                      "a named text file from Files is a file")
        XCTAssertFalse(TransferDropFilter.isFile(typeIdentifiers: [UTType.utf8PlainText.identifier], suggestedName: nil),
                       "a snippet of dragged text is not")
        XCTAssertFalse(TransferDropFilter.isFile(typeIdentifiers: [UTType.url.identifier], suggestedName: nil))
    }

    func testTheMostSpecificDataTypeIsRequested() {
        XCTAssertEqual(TransferDropFilter.preferredType(among: ["com.apple.foo-unknown-type", UTType.png.identifier,
                                                                UTType.data.identifier]), UTType.png.identifier)
    }

    func testStagedNamesKeepOrGainAnExtension() {
        let loaded = URL(fileURLWithPath: "/tmp/.provider/IMG_0001.heic")
        XCTAssertEqual(TransferDropLoader.stagedName(suggested: "Beach", loaded: loaded, type: UTType.jpeg.identifier), "Beach.jpeg")
        XCTAssertEqual(TransferDropLoader.stagedName(suggested: "Beach.png", loaded: loaded, type: UTType.jpeg.identifier), "Beach.png")
        XCTAssertEqual(TransferDropLoader.stagedName(suggested: nil, loaded: loaded, type: UTType.jpeg.identifier), "IMG_0001.heic")
    }

    // MARK: - Staging

    func testStagingCopiesAndDiscardRemovesOnlyStagedFiles() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("stage-src-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try OutgoingFileStaging.stage(source, securityScoped: false)
        XCTAssertEqual(try Data(contentsOf: staged), Data("hello".utf8))
        XCTAssertEqual(staged.lastPathComponent, source.lastPathComponent)

        OutgoingFileStaging.discard(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "a file outside staging is left alone")
        OutgoingFileStaging.discard(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testStagingAMissingFileSaysWhichFile() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/gone.bin")
        XCTAssertThrowsError(try OutgoingFileStaging.stage(missing, securityScoped: false)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("gone.bin could not be read"))
        }
    }

    // MARK: - Pause only where it means something

    func testInboundTransfersCannotBePaused() {
        var inbound = BulkTransfer(id: UUID(), fileName: "a", fileSize: 10, destination: "P", direction: .inbound)
        inbound.status = .sending
        XCTAssertFalse(inbound.canPause)
        inbound.status = .paused
        XCTAssertFalse(inbound.canResume)
        var outbound = BulkTransfer(id: UUID(), fileName: "a", fileSize: 10, destination: "P", direction: .outbound)
        outbound.status = .sending
        XCTAssertTrue(outbound.canPause)
        outbound.status = .paused
        XCTAssertTrue(outbound.canResume)
    }

    func testTerminalStatuses() {
        XCTAssertTrue(BulkTransferStatus.completed.isTerminal)
        XCTAssertTrue(BulkTransferStatus.cancelled.isTerminal)
        XCTAssertTrue(BulkTransferStatus.failed(reason: "").isTerminal)
        for status in [BulkTransferStatus.pending, .awaitingAcceptance, .sending, .paused, .awaitingCompletion] {
            XCTAssertFalse(status.isTerminal)
        }
    }
}
