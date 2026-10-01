import XCTest
import UniformTypeIdentifiers
@testable import AXTerm

/// Where the Files screens keep what an open picker is for.
///
/// SwiftUI closes a file importer by setting its `isPresented` binding to
/// false before it calls the completion handler. The screens kept the pick's
/// purpose in the very state that binding cleared, so by the time the
/// handler ran there was nothing left to act on: on the live test of
/// 2026-10-01, "Share a Folder" on the Mac closed the panel and shared
/// nothing, with no message. These pin that the purpose outlives the panel.
final class BBSFilePickerStateTests: XCTestCase {

    func testThePurposeSurvivesThePanelClosingFirst() {
        var picker = BBSFilePicker()
        picker.begin(.shareFolder)
        XCTAssertTrue(picker.isPresented)

        picker.panelClosed()

        XCTAssertFalse(picker.isPresented)
        XCTAssertEqual(picker.finish(), .shareFolder,
                       "the panel closing first left the pick with no purpose, so it did nothing")
    }

    func testThePurposeIsHandedOutOnce() {
        var picker = BBSFilePicker()
        picker.begin(.addFiles(area: "TEST"))

        XCTAssertEqual(picker.finish(), .addFiles(area: "TEST"))
        XCTAssertNil(picker.finish())
        XCTAssertFalse(picker.isPresented)
    }

    func testANewPickReplacesAnOldOne() {
        var picker = BBSFilePicker()
        picker.begin(.uploadInbox)
        picker.panelClosed()   // canceled: no completion follows
        picker.begin(.relocate(area: "OLD"))

        XCTAssertEqual(picker.finish(), .relocate(area: "OLD"))
    }

    func testWhatThePanelAcceptsFollowsThePurpose() {
        var picker = BBSFilePicker()
        picker.begin(.addFiles(area: "TEST"))
        XCTAssertEqual(picker.contentTypes, BBSFilePickPurpose.addFiles(area: "TEST").contentTypes)
        XCTAssertTrue(picker.allowsMultipleSelection)

        picker.begin(.shareFolder)
        XCTAssertEqual(picker.contentTypes, [.folder])
        XCTAssertFalse(picker.allowsMultipleSelection)
    }
}
