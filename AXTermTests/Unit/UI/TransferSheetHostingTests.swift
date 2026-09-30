//
//  TransferSheetHostingTests.swift
//  AXTermTests
//
//  The transfer sheets and list, laid out for real, off screen. The Mac keeps
//  its fixed sheet sizes (iPhone and iPad size to the device, which is the
//  other branch of PlatformSheetFrame), and nothing publishes from inside a
//  view update: the offer prompt now lives on the main window, where a
//  publish-during-update would fire on every offer.
//

#if os(macOS)
import AppKit
import OSLog
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class TransferSheetHostingTests: XCTestCase {

    private func host<V: View>(_ view: V, width: CGFloat = 700, height: CGFloat = 700) -> (NSWindow, NSHostingView<V>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        return (window, hosting)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func publishWarnings(since start: Date) throws -> Int {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(
            at: store.position(date: start.addingTimeInterval(-1)),
            matching: NSPredicate(format: "subsystem == %@", "com.apple.runtime-issues"))
        return entries
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.date >= start && $0.composedMessage.contains("Publishing changes from within view updates") }
            .count
    }

    private func request(protocol type: TransferProtocolType = .axdp, airtime: TimeInterval? = nil) -> IncomingTransferRequest {
        IncomingTransferRequest(sourceCallsign: "N0CALL-7", fileName: "a-rather-long-file-name-for-a-phone.zip",
                                fileSize: 48_000, axdpSessionId: 42, transferProtocol: type,
                                estimatedAirtimeSeconds: airtime)
    }

    // MARK: - Sizes

    func testTheSendSheetKeepsItsMacSize() throws {
        let sheet = SendFileSheet(isPresented: .constant(true), selectedFileURL: nil, connectedSessions: [],
                                  onSend: { _, _, _, _ in })
        let (window, hosting) = host(sheet)
        defer { window.close() }
        spin(0.3)
        XCTAssertEqual(hosting.fittingSize.width, 560, accuracy: 0.5)
        XCTAssertEqual(hosting.fittingSize.height, 620, accuracy: 0.5)
    }

    func testTheOfferSheetKeepsItsMacWidth() throws {
        let sheet = IncomingTransferSheet(isPresented: .constant(true), request: request(airtime: 600),
                                          onAccept: {}, onDecline: {}, onAlwaysAccept: {}, onAlwaysDeny: {})
        let (window, hosting) = host(sheet)
        defer { window.close() }
        spin(0.3)
        XCTAssertEqual(hosting.fittingSize.width, 450, accuracy: 0.5)
    }

    // MARK: - No publishing during updates

    func testTheSheetsAndListRenderWithoutPublishingDuringUpdates() throws {
        let start = Date()

        let send = host(SendFileSheet(isPresented: .constant(true), selectedFileURL: nil, connectedSessions: [],
                                      onSend: { _, _, _, _ in }))
        let offer = host(IncomingTransferSheet(isPresented: .constant(true), request: request(protocol: .yapp),
                                               onAccept: {}, onDecline: {}, onAlwaysAccept: {}, onAlwaysDeny: {}))

        var received = BulkTransfer(id: UUID(), fileName: "KEPS.TXT", fileSize: 900, destination: "N0CALL",
                                    direction: .inbound)
        received.status = .completed
        received.savedFilePath = "/tmp/AXTerm Transfers/KEPS.TXT"
        var sending = BulkTransfer(id: UUID(), fileName: "out.bin", fileSize: 9000, destination: "N0CALL")
        sending.status = .awaitingAcceptance
        let pending = request()
        let list = host(BulkTransferListView(
            transfers: [received, sending],
            pendingIncomingTransfers: [pending],
            onPause: { _ in }, onResume: { _ in }, onCancel: { _ in },
            onClearCompleted: {}, onAddFile: {},
            onAcceptIncoming: { _ in }, onDeclineIncoming: { _ in }))
        defer {
            send.0.close()
            offer.0.close()
            list.0.close()
        }
        spin(0.5)
        XCTAssertEqual(try publishWarnings(since: start), 0)
    }

    /// The prompt host on a window, fed offers the way the coordinator feeds
    /// them: appearing, being answered elsewhere, and a second one queued.
    func testThePromptHostFollowsTheOffersWithoutPublishingDuringUpdates() throws {
        let defaults = TestDefaults.make("TransferPromptHost")
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        let coordinator = SessionCoordinator()
        let view = Color.clear.frame(width: 400, height: 300)
            .modifier(IncomingTransferPromptHost(coordinator: coordinator, settings: settings))
        let (window, _) = host(view)
        defer { window.close() }
        spin(0.3)

        let start = Date()
        let first = request()
        let second = IncomingTransferRequest(sourceCallsign: "K1ABC", fileName: "two.txt", fileSize: 10,
                                             axdpSessionId: 7)
        coordinator.pendingIncomingTransfers.append(first)
        spin(0.3)
        coordinator.pendingIncomingTransfers.append(second)
        spin(0.3)
        coordinator.pendingIncomingTransfers.removeAll { $0.id == first.id }
        spin(0.3)
        coordinator.pendingIncomingTransfers.removeAll()
        spin(0.3)
        XCTAssertEqual(try publishWarnings(since: start), 0)
        withExtendedLifetime(coordinator) {}
    }

    func testReceivedFileActionsRenderForASavedFile() throws {
        let start = Date()
        let (window, hosting) = host(ReceivedFileActions(path: "/tmp/AXTerm Transfers/photo.jpg"), width: 500, height: 80)
        defer { window.close() }
        spin(0.3)
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        XCTAssertEqual(try publishWarnings(since: start), 0)
    }
}
#endif
