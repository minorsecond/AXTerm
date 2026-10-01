//
//  DestinationPickerTypingHostingTests.swift
//  AXTermTests
//
//  The terminal's To field, typed into for real, off screen.
//
//  Live RF test 2026-09-30 (bug 3): typing K0EPI-2 on station B left "K".
//  Every keystroke went straight out as the terminal's destination, and the
//  first one, "K", was enough to bind the terminal to the live session and
//  replace the field with a locked label. Typing must stay in the field
//  until the operator picks a suggestion or presses Return.
//

#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class DestinationPickerTypingHostingTests: XCTestCase {

    private final class Recorder {
        var changed: [String] = []
        var committed: [String] = []
    }

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        return window
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { found.append(field) }
        for child in view.subviews { found += textFields(in: child) }
        return found
    }

    /// Station B had heard K0EPI-2, so the suggestion list had something to
    /// offer from the first keystroke.
    private let groups = [ConnectSuggestionGroup(id: "recent", title: "Recent", values: ["K0EPI-2", "KB5YZB-7"])]

    private func makePicker(_ recorder: Recorder) -> (DestinationPickerViewModel, some View) {
        let model = DestinationPickerViewModel(defaults: TestDefaults.make("DestinationPickerTyping"))
        let view = DestinationPickerControl(
            viewModel: model, externalText: "", groups: groups, disabled: false,
            onDestinationChanged: { recorder.changed.append($0) },
            onDestinationCommitted: { recorder.committed.append($0) })
            .frame(width: 300)
        return (model, view)
    }

    func testTypingAFullCallsignStaysInTheField() throws {
        let recorder = Recorder()
        let (model, view) = makePicker(recorder)
        let window = host(view)
        defer { window.close() }
        spin(0.3)

        let field = try XCTUnwrap(Self.textFields(in: window.contentView).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        for character in "k0epi-2" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            spin(0.1)
        }

        XCTAssertEqual(field.stringValue, "K0EPI-2", "what the operator sees")
        XCTAssertEqual(model.typedText, "K0EPI-2")
        XCTAssertTrue(window.firstResponder === field.currentEditor(),
                      "the field lost focus partway through the callsign")
        XCTAssertEqual(recorder.changed, [],
                       "each keystroke went out as the destination: \(recorder.changed)")
        XCTAssertEqual(recorder.committed, [])
    }

    func testReturnCommitsWhatWasTyped() throws {
        let recorder = Recorder()
        let (_, view) = makePicker(recorder)
        let window = host(view)
        defer { window.close() }
        spin(0.3)

        let field = try XCTUnwrap(Self.textFields(in: window.contentView).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        for character in "K0EPI-2" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            spin(0.05)
        }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        spin(0.2)

        XCTAssertEqual(recorder.committed, ["K0EPI-2"])
    }
}
#endif
