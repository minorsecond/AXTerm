//
//  WinlinkComposeHostingTests.swift
//  AXTermTests
//
//  The compose window and the reading pane, hosted off-screen at an iPhone's
//  width, an iPad sheet's width and a Mac window's, while attachments arrive,
//  get shrunk and are saved. Each counts the "Publishing changes from within
//  view updates" runtime issues SwiftUI logs for this process, which is how
//  a model mutated from inside a body shows up (see
//  SettingsSidebarPublishTests).
//

#if os(macOS)
import AppKit
import GRDB
import OSLog
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class WinlinkComposeHostingTests: XCTestCase {

    private static let photo: Data = SyntheticPhoto.data(width: 1800, height: 1200, seed: 11)!

    /// iPhone 16 (393), an iPad form sheet (~700) and a Mac compose window.
    private static let widths: [(String, CGFloat, CGFloat)] = [
        ("iPhone", 393, 760), ("iPad", 700, 900), ("Mac", 640, 520),
    ]

    private func makeStore() throws -> SQLiteWinlinkStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteWinlinkStore(dbQueue: queue)
    }

    private func saveDraft(in store: SQLiteWinlinkStore, attachments: [WinlinkB2Message.Attachment] = []) throws -> String {
        let draft = WinlinkB2Message(mid: WinlinkB2Message.generateMID(callsign: "K0EPI"), date: Date(),
                                     type: .privateMessage, from: "K0EPI", to: ["W1AW"], cc: [],
                                     subject: "Hosting", mbo: "K0EPI", body: Data("Body".utf8),
                                     attachments: attachments)
        try store.saveDraft(draft)
        return draft.mid
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        return window
    }

    private func spin(until deadline: TimeInterval, _ done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end && !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testComposeWithArrivingAttachmentsDoesNotPublishDuringViewUpdates() throws {
        for (label, width, height) in Self.widths {
            let store = try makeStore()
            let mid = try saveDraft(in: store)
            var changes = 0
            let files = [ComposeIncomingFile(name: "IMG_0001.HEIC", data: Self.photo),
                         ComposeIncomingFile(name: "notes.txt",
                                             data: Data(String(repeating: "73 de K0EPI\n", count: 400).utf8))]
            let start = Date()
            let window = host(NavigationStack {
                WinlinkComposeWindow(store: store, myCallsign: "K0EPI", draftMID: mid,
                                     initialFiles: files, onChanged: { changes += 1 })
            }, width: width, height: height)
            spin(until: 15) { changes > 0 }
            spin(until: 0.3)
            window.close()

            XCTAssertEqual(changes, 1, "\(label): the arriving files were saved into the draft once")
            let saved = try XCTUnwrap(try store.message(mid: mid)).message
            XCTAssertEqual(saved.attachments.map(\.name), ["IMG_0001.jpg", "notes.txt.zip"], label)
            XCTAssertLessThanOrEqual(saved.attachments.reduce(0) { $0 + $1.data.count },
                                     WinlinkComposeViewModel.messageSizeBudget, label)
            XCTAssertEqual(try Self.publishWarnings(since: start), 0,
                           "\(label): compose published from inside a view update")
        }
    }

    func testAnEmptyComposeRendersAtEveryWidth() throws {
        for (label, width, height) in Self.widths {
            let store = try makeStore()
            let mid = try saveDraft(in: store)
            let start = Date()
            let window = host(NavigationStack {
                WinlinkComposeWindow(store: store, myCallsign: "K0EPI", draftMID: mid, onChanged: {})
            }, width: width, height: height)
            spin(until: 0.5)
            window.close()
            XCTAssertEqual(try Self.publishWarnings(since: start), 0, "\(label): empty compose")
        }
    }

    func testTheReadingPaneWritesPreviewCopiesWithoutPublishingDuringUpdates() throws {
        let store = try makeStore()
        let jpeg = try XCTUnwrap(SyntheticPhoto.data(width: 300, height: 200))
        let mid = try saveDraft(in: store, attachments: [.init(name: "chart.jpg", data: jpeg),
                                                         .init(name: "notes.txt", data: Data("73".utf8))])
        let stored = try XCTUnwrap(try store.message(mid: mid))
        for (label, width, height) in Self.widths {
            let start = Date()
            let window = host(WinlinkMessageDetail(stored: stored, onReply: { _ in }, onForward: {}),
                              width: width, height: height)
            spin(until: 1.0)
            window.close()
            XCTAssertEqual(try Self.publishWarnings(since: start), 0, "\(label): reading pane")
        }
        let folder = AttachmentPreviewFiles.directory(for: mid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("chart.jpg").path),
                      "Quick Look has a file to show")
        try? FileManager.default.removeItem(at: folder)
    }

    /// SwiftUI reports the problem as a runtime issue in this process's log.
    private static func publishWarnings(since start: Date) throws -> Int {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(
            at: store.position(date: start.addingTimeInterval(-1)),
            matching: NSPredicate(format: "subsystem == %@", "com.apple.runtime-issues"))
        return entries
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.date >= start && $0.composedMessage.contains("Publishing changes from within view updates") }
            .count
    }
}
#endif
