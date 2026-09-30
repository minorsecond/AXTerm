//
//  CallsignInputPublishTests.swift
//  AXTermTests
//
//  Callsign fields upper-case as the operator types. The rewrite happens in
//  onChange (see `callsignInput`), so these host real fields off-screen,
//  write lower case into what they edit, and check that it settles upper
//  case without SwiftUI logging a publish from inside a view update.
//

#if os(macOS)
import AppKit
import Combine
import OSLog
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class CallsignInputPublishTests: XCTestCase {

    // MARK: - Fixtures

    private final class Box: ObservableObject {
        @Published var text = ""
    }

    private struct BoxedField: View {
        @ObservedObject var box: Box
        var body: some View {
            TextField("Call", text: $box.text)
                .callsignInput($box.text)
        }
    }

    private struct BoxedCallsignField: View {
        @ObservedObject var box: Box
        var body: some View { CallsignField(title: "NOCALL", text: $box.text) }
    }

    private struct BoxedPathRow: View {
        @ObservedObject var box: Box
        var body: some View { Form { RadioAPRSPathRow(path: $box.text) } }
    }

    private struct BoxedComboBox: View {
        @ObservedObject var box: Box
        var body: some View {
            EditableComboBox(text: $box.text, placeholder: "Destination",
                             items: ["K0EPI-7"], width: 200, uppercases: true)
        }
    }

    private func settings(_ label: String) -> AppSettingsStore {
        let defaults = TestDefaults.make(label)
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "K0EPI"
        for radio in settings.radios {
            settings.updateRadio(radio.id) {
                $0.enabled = false
                $0.host = "127.0.0.1"
                $0.port = 9
            }
        }
        return settings
    }

    /// Never ordered front, as in SettingsSidebarPublishTests.
    private func host<V: View>(_ view: V, width: CGFloat = 700, height: CGFloat = 900) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        return window
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spins until `condition` holds or `timeout` passes.
    private func settle(timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { spin(0.05) }
    }

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

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { found.append(field) }
        for child in view.subviews { found += textFields(in: child) }
        return found
    }

    // MARK: - Driving the binding

    func testPlainFieldsSettleUpperCase() throws {
        let box = Box(), called = Box(), path = Box(), combo = Box()
        let windows = [host(BoxedField(box: box), width: 300, height: 80),
                       host(BoxedCallsignField(box: called), width: 300, height: 80),
                       host(BoxedPathRow(box: path), width: 500, height: 200),
                       host(BoxedComboBox(box: combo), width: 300, height: 80)]
        defer { windows.forEach { $0.close() } }
        spin(0.4)

        let start = Date()
        box.text = "k0epi-7"
        called.text = "kb5yzb-7"
        path.text = "wide1-1,wide2-1"
        combo.text = "drlnod"
        settle { box.text == "K0EPI-7" && called.text == "KB5YZB-7"
                 && path.text == "WIDE1-1,WIDE2-1" }
        spin(0.2)

        XCTAssertEqual(box.text, "K0EPI-7")
        XCTAssertEqual(called.text, "KB5YZB-7", "CallsignField")
        XCTAssertEqual(path.text, "WIDE1-1,WIDE2-1", "the APRS path row")
        XCTAssertEqual(combo.text, "drlnod",
                       "the Mac combo box upper-cases what is typed into it, not what its owner sets")
        XCTAssertEqual(try Self.publishWarnings(since: start), 0)
    }

    func testAlreadyUpperCaseIsNotWrittenAgain() {
        let box = Box()
        let window = host(BoxedField(box: box), width: 300, height: 80)
        defer { window.close() }
        spin(0.3)

        var writes = 0
        let watch = box.$text.dropFirst().sink { _ in writes += 1 }
        defer { watch.cancel() }
        box.text = "K0EPI"
        spin(0.3)
        XCTAssertEqual(writes, 1, "only the test's own write; nothing to rewrite")

        box.text = "k0epi"
        settle { box.text == "K0EPI" }
        spin(0.2)
        XCTAssertEqual(writes, 3, "the lower case, then one rewrite, and it stops")
    }

    func testTheGridSquareFieldTakesTheConventionalCase() throws {
        let defaults = TestDefaults.make("CallsignInputGrid")
        let winlink = WinlinkSettings(defaults: defaults,
                                      keychain: KeychainStore(service: "test-\(UUID().uuidString)"))
        let window = host(GridSquareTextField(winlinkSettings: winlink), width: 200, height: 60)
        defer { window.close() }
        spin(0.3)

        let start = Date()
        winlink.gridSquare = "dm79PO"
        settle { winlink.gridSquare == "DM79po" }
        XCTAssertEqual(winlink.gridSquare, "DM79po")
        XCTAssertEqual(try Self.publishWarnings(since: start), 0)
    }

    func testThePacketNodePageUpperCasesItsCallsignFields() throws {
        let settings = settings("CallsignInputPacketNode")
        _ = settings.addRadio()
        let packet = try XCTUnwrap(settings.activeRadios.last?.id)
        settings.netRomNodeIdentity = .perRadio
        settings.updateRadio(packet) {
            RadioChannel.packet.apply(to: &$0)
            $0.announcesNode = true
            $0.beacon.enabled = true
            $0.digi.enabled = true
        }
        let client = PacketEngine(settings: settings)
        let page = PacketNodeSettingsView(settings: settings, client: client)
            .environmentObject(SettingsRouter.shared)
        let window = host(page)
        defer { window.close() }
        spin(0.5)

        let start = Date()
        settings.netRomNodeAlias = "epinod"
        settings.updateRadio(packet) {
            $0.netRomAlias = "uhfnod"
            $0.digi.aliases = ["club"]
            $0.beacon.path = "wide1-1"
        }
        settle {
            settings.netRomNodeAlias == "EPINOD" && settings.radio(packet)?.netRomAlias == "UHFNOD"
                && settings.radio(packet)?.digi.aliases == ["CLUB"]
                && settings.radio(packet)?.beacon.path == "WIDE1-1"
        }
        spin(0.2)

        XCTAssertEqual(settings.netRomNodeAlias, "EPINOD", "the station's node alias")
        XCTAssertEqual(settings.radio(packet)?.netRomAlias, "UHFNOD", "the node alias on this radio")
        XCTAssertEqual(settings.radio(packet)?.digi.aliases, ["CLUB"], "Also answer to")
        XCTAssertEqual(settings.radio(packet)?.beacon.path, "WIDE1-1", "the ID beacon's digipeaters")
        XCTAssertEqual(try Self.publishWarnings(since: start), 0)
    }

    func testTheMailboxCallsignSettlesUpperCase() throws {
        let bbs = BBSSettings(defaults: TestDefaults.make("CallsignInputBBS"))
        let window = host(BBSSettingsTab(settings: bbs, stationCallsign: "K0EPI",
                                         isWinlinkP2PArmed: false))
        defer { window.close() }
        spin(0.5)

        let start = Date()
        bbs.callsign = "k0epi-4"
        settle { bbs.callsign == "K0EPI-4" }
        XCTAssertEqual(bbs.callsign, "K0EPI-4")
        XCTAssertEqual(try Self.publishWarnings(since: start), 0)
    }

    // MARK: - Typing

    /// Typing into the middle of a callsign: the letter lands upper case and
    /// the caret stays after it.
    func testTypingMidwayUpperCasesAndKeepsTheCaret() throws {
        let box = Box()
        box.text = "K0PI"
        let window = host(BoxedField(box: box), width: 300, height: 80)
        defer { window.close() }
        spin(0.3)

        let field = try XCTUnwrap(Self.textFields(in: window.contentView).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))

        let start = Date()
        editor.insertText("e", replacementRange: editor.selectedRange())
        settle { box.text == "K0EPI" }
        spin(0.2)

        XCTAssertEqual(box.text, "K0EPI")
        XCTAssertEqual(field.stringValue, "K0EPI", "what the operator sees")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0),
                       "the caret stays after the typed letter")
        XCTAssertEqual(try Self.publishWarnings(since: start), 0)
    }

    func testTypingIntoTheComboBoxUpperCasesInPlace() throws {
        let box = Box()
        box.text = "K0PI"
        let window = host(BoxedComboBox(box: box), width: 300, height: 80)
        defer { window.close() }
        spin(0.3)

        let field = try XCTUnwrap(Self.textFields(in: window.contentView).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))

        let start = Date()
        editor.insertText("e", replacementRange: editor.selectedRange())
        settle { box.text == "K0EPI" }
        spin(0.2)

        XCTAssertEqual(box.text, "K0EPI")
        XCTAssertEqual(editor.string, "K0EPI", "what the operator sees")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(try Self.publishWarnings(since: start), 0)
    }
}
#endif
