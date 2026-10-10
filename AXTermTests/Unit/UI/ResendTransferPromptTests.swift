import XCTest
@testable import AXTerm

/// The question Send Again asks before a file goes on the air again (home
/// retest findings 5 and 10).
final class ResendTransferPromptTests: XCTestCase {

    func testAnAXDPTransferOffersItsOwnProtocolAndYAPP() {
        let prompt = ResendTransferPrompt(fileName: "photo.jpg", destination: "K0EPI-4", choices: [.axdp, .yapp])
        XCTAssertEqual(prompt.title, "Send photo.jpg to K0EPI-4 again?")
        XCTAssertEqual(prompt.message, "It goes as a new transfer. This one stays in the list as it is.")
        XCTAssertEqual(prompt.options, [
            ResendTransferPrompt.Option(label: "Send Again by AXDP", transferProtocol: .axdp),
            ResendTransferPrompt.Option(label: "Send with YAPP Instead", transferProtocol: .yapp),
        ])
    }

    func testOneProtocolIsJustSendAgain() {
        let prompt = ResendTransferPrompt(fileName: "photo.jpg", destination: "K0EPI-4", choices: [.yapp])
        XCTAssertEqual(prompt.options, [ResendTransferPrompt.Option(label: "Send Again", transferProtocol: .yapp)])
    }
}
