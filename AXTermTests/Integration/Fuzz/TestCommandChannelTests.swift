//
//  TestCommandChannelTests.swift
//  AXTermTests
//
//  The test-mode command folder: the smoke test drives transfers and session
//  text through it instead of the file picker and screen clicks.
//
//  A JSON file dropped in the folder runs once, through the same
//  SessionCoordinator calls the buttons use, and leaves a .result.json
//  beside it. Smoke run 2026-10-03-1: every file test needed a click in an
//  Open panel, and a click meant for one landed on a window the test driver
//  could not see.
//

import XCTest
@testable import AXTerm

@MainActor
final class TestCommandChannelTests: XCTestCase {

    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    private func makeFolder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestCommands-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    private func connectedPair() async -> (FuzzStation, FuzzStation) {
        let a = FuzzStation(callsign: "K0AAA-1", seed: 1)
        let b = FuzzStation(callsign: "K0BBB-2", seed: 2)
        a.connectLink(to: b)
        b.connectLink(to: a)
        return (a, b)
    }

    private func drop(_ json: String, named name: String, in folder: URL) {
        try? Data(json.utf8).write(to: folder.appendingPathComponent(name + ".json"))
    }

    private func result(_ name: String, in folder: URL) -> [String: Any]? {
        let url = folder.appendingPathComponent(name + ".result.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testConnectSendFileAcceptAndDisconnect() async {
        let (a, b) = await connectedPair()
        defer { a.tearDown(); b.tearDown() }
        let commandsA = makeFolder("A"), commandsB = makeFolder("B"), files = makeFolder("files")
        let data = Data((0..<3000).map { UInt8($0 % 251) })
        try? data.write(to: files.appendingPathComponent("t3k.bin"))
        let channelA = TestCommandChannel(folder: commandsA, coordinator: a.coordinator, filesFolder: files)
        let channelB = TestCommandChannel(folder: commandsB, coordinator: b.coordinator, filesFolder: files)

        drop(#"{"action":"connect","to":"K0BBB-2"}"#, named: "01-connect", in: commandsA)
        channelA.poll()
        XCTAssertEqual(result("01-connect", in: commandsA)?["ok"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandsA.appendingPathComponent("01-connect.json").path),
                       "a command runs once")
        let up = await FullStackFuzz.wait(10) { a.session != nil && b.session != nil }
        XCTAssertTrue(up)
        a.coordinator.markImplicitlyConfirmedAXDP(for: b.callsign)
        b.coordinator.markImplicitlyConfirmedAXDP(for: a.callsign)

        drop(#"{"action":"sendFile","to":"K0BBB-2","file":"t3k.bin","protocol":"axdp","compression":"off"}"#,
             named: "02-send", in: commandsA)
        channelA.poll()
        // The file is read off the main actor, and the result comes after.
        let answered = await FullStackFuzz.wait(10) { self.result("02-send", in: commandsA) != nil }
        XCTAssertTrue(answered)
        XCTAssertEqual(result("02-send", in: commandsA)?["ok"] as? Bool, true, "\(String(describing: result("02-send", in: commandsA)))")
        let offered = await FullStackFuzz.wait(10) { !b.coordinator.pendingIncomingTransfers.isEmpty }
        XCTAssertTrue(offered)

        drop(#"{"action":"acceptOffer","file":"t3k.bin"}"#, named: "03-accept", in: commandsB)
        channelB.poll()
        XCTAssertEqual(result("03-accept", in: commandsB)?["ok"] as? Bool, true)
        let done = await FullStackFuzz.wait(30) { b.transfer(named: "t3k.bin")?.status == .completed }
        XCTAssertTrue(done)
        XCTAssertEqual(b.savedData(b.transfer(named: "t3k.bin")), data)

        drop(#"{"action":"disconnect","to":"K0BBB-2"}"#, named: "04-disconnect", in: commandsA)
        channelA.poll()
        XCTAssertEqual(result("04-disconnect", in: commandsA)?["ok"] as? Bool, true)
        let down = await FullStackFuzz.wait(10) { a.session == nil }
        XCTAssertTrue(down)
    }

    func testSendTextGoesOverTheSession() async {
        let (a, b) = await connectedPair()
        defer { a.tearDown(); b.tearDown() }
        let commands = makeFolder("A")
        let channel = TestCommandChannel(folder: commands, coordinator: a.coordinator, filesFolder: commands)
        if let sabm = a.coordinator.sessionManager.connect(to: b.address, path: DigiPath(),
                                                           radio: a.coordinator.primaryRadioID) {
            a.coordinator.sendFrame(sabm)
        }
        let up = await FullStackFuzz.wait(10) { a.session != nil && b.session != nil }
        XCTAssertTrue(up)

        drop(#"{"action":"sendText","to":"K0BBB-2","text":"smoke 6.2 hello"}"#, named: "text", in: commands)
        channel.poll()

        XCTAssertEqual(result("text", in: commands)?["ok"] as? Bool, true)
        let arrived = await FullStackFuzz.wait(5) {
            b.terminalText.range(of: Data("smoke 6.2 hello\r".utf8)) != nil
        }
        XCTAssertTrue(arrived)
    }

    func testABadCommandReportsWhyAndRunsNothing() {
        let a = FuzzStation(callsign: "K0AAA-1", seed: 1)
        defer { a.tearDown() }
        let commands = makeFolder("A")
        let channel = TestCommandChannel(folder: commands, coordinator: a.coordinator, filesFolder: commands)

        drop(#"{"action":"launchMissiles"}"#, named: "unknown", in: commands)
        drop("not json", named: "garbled", in: commands)
        drop(#"{"action":"sendFile","to":"K0BBB-2","file":"../../etc/passwd"}"#, named: "escape", in: commands)
        channel.poll()

        for name in ["unknown", "garbled", "escape"] {
            XCTAssertEqual(result(name, in: commands)?["ok"] as? Bool, false, name)
            XCTAssertNotNil(result(name, in: commands)?["error"] as? String, name)
        }
        XCTAssertTrue(a.coordinator.transfers.isEmpty)
    }

    /// Commands run in name order, so a script can number them.
    func testCommandsRunInNameOrder() {
        let a = FuzzStation(callsign: "K0AAA-1", seed: 1)
        defer { a.tearDown() }
        let commands = makeFolder("A")
        let channel = TestCommandChannel(folder: commands, coordinator: a.coordinator, filesFolder: commands)
        drop(#"{"action":"nope2"}"#, named: "02", in: commands)
        drop(#"{"action":"nope1"}"#, named: "01", in: commands)

        XCTAssertEqual(channel.poll(), ["01", "02"])
    }
}
