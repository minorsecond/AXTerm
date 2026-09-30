import XCTest
@testable import AXTerm

/// The packet list's tag for a frame: APRS frames by their data type, other
/// UI frames in the terminal chips' words, connected-mode frames by their
/// control field.
final class PacketTypeTagTests: XCTestCase {

    private func ui(_ info: String, to: String = "APRS", from: String = "K0EPI") -> Packet {
        Packet(from: AX25Address(call: from), to: AX25Address(call: to),
               frameType: .ui, control: 0x03, pid: 0xF0, info: Data(info.utf8))
    }

    private func label(_ info: String, to: String = "APRS") -> String {
        PacketTypeTag.of(ui(info, to: to)).label
    }

    func testPositionReportsArePOS() {
        XCTAssertEqual(label("!3953.87N/10458.21W-000/000KF0HEG-9 BASE"), "POS")
        XCTAssertEqual(label("@301534z3934.15N/10455.05W-WX3in1Mini U=12.4V."), "POS")
    }

    func testMicEPositionsAreMarkedAsMicE() {
        XCTAssertEqual(label("\u{60}pEzn6cR/\u{60}\"Hd]_4", to: "SYSQSQ"), "MIC-E")
    }

    func testObjectsAndItemsAreTaggedApart() {
        XCTAssertEqual(label(";147.285CO*111111z3826.78N/10600.65WrT88 R40m"), "OBJ")
        XCTAssertEqual(label(")AID#2!4903.50N/07201.75WA"), "ITEM")
    }

    func testStatusReportsAreSTATUS() {
        XCTAssertEqual(label(">ARES R1D5 Weekly Net Thur 20:00"), "STATUS")
    }

    func testTelemetryReportsAndTheirSetupMessagesAreTLM() {
        XCTAssertEqual(label("T#207,126,029,073,041,048,00000000"), "TLM")
        XCTAssertEqual(label(":SIMLA    :UNIT.Volt,Pkt,Pkt,Pcnt,None"), "TLM")
        XCTAssertEqual(label(":SIMLA    :BITS.11111111,WX3in1Plus20 Telemetry"), "TLM")
    }

    func testTheMessageClass() {
        XCTAssertEqual(label(":K0EPI-7  :Are you on the net?{12"), "MSG")
        XCTAssertEqual(label(":K0EPI-7  :ack12"), "MSG ACK")
        XCTAssertEqual(label(":BLN1     :Net tonight at 8"), "BLN")
    }

    func testPositionlessWeatherIsWX() {
        XCTAssertEqual(label("_10090556c220s004g005t077r000p000P000h50b09900"), "WX")
    }

    /// Non-APRS UI frames use the terminal's words, so the list and the
    /// filter chips name the same lines the same way.
    func testPlainUIFramesUseTheTerminalChipWords() {
        XCTAssertEqual(label("KD0SSP-7 Aurora node", to: "ID"), "ID")
        XCTAssertEqual(label("Mail for: K0EPI", to: "MAIL"), "MAIL")
        XCTAssertEqual(label("Just a beacon", to: "BEACON"), "BCN")
        XCTAssertEqual(PacketClassification.uiBeacon.badge,
                       ConsoleTypeFilterFlags.Kind.beacon.label)
    }

    func testConnectedModeFramesKeepTheirControlFieldTag() {
        let iFrame = Packet(from: AX25Address(call: "K0EPI"), to: AX25Address(call: "W0ARP", ssid: 10),
                            frameType: .i, control: 0x00, pid: 0xF0, info: Data("hello".utf8))
        XCTAssertEqual(PacketTypeTag.of(iFrame).label, "DATA")
    }

    func testTheRowViewModelCarriesTheTag() {
        let row = PacketRowViewModel.fromPacket(ui(">Net tonight"))
        XCTAssertEqual(row.typeLabel, "STATUS")
        XCTAssertFalse(row.typeTooltip.contains("\u{2014}"))
    }

    func testNoTooltipUsesAnEmDash() {
        let samples = ["!3953.87N/10458.21W-", ">status", "T#1,2,3,4,5,6,00000000",
                       ":K0EPI-7  :hi{1", ";OBJECT   *111111z3826.78N/10600.65WrX"]
        for info in samples {
            XCTAssertFalse(PacketTypeTag.of(ui(info)).tooltip.contains("\u{2014}"), info)
        }
    }
}

/// The packet list's copy marks, decided the way the terminal decides "+1".
final class PacketDuplicatesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func beacon(at offset: TimeInterval, via: [String]) -> Packet {
        Packet(timestamp: start.addingTimeInterval(offset),
               from: AX25Address(call: "K5RHD"), to: AX25Address(call: "SYUPZZ"),
               via: via.map { AX25Address(call: $0, repeated: true) },
               frameType: .ui, control: 0x03, pid: 0xF0, info: Data("`q]+l -/]".utf8))
    }

    func testADigipeatedCopyIsMarkedAndTheOriginalCounted() {
        let first = beacon(at: 0, via: [])
        let copy = beacon(at: 2, via: ["WQ8M-9"])
        let marks = PacketDuplicates.marks(for: [first, copy])
        XCTAssertEqual(marks[first.id], .heardAgain(1))
        XCTAssertEqual(marks[copy.id], .copy(of: first.id))
    }

    func testTwoCopiesCountTwo() {
        let first = beacon(at: 0, via: [])
        let a = beacon(at: 1, via: ["WQ8M-9"])
        let b = beacon(at: 3, via: ["WA6IFI-6"])
        let marks = PacketDuplicates.marks(for: [first, a, b])
        XCTAssertEqual(marks[first.id], .heardAgain(2))
        XCTAssertEqual(marks[b.id], .copy(of: first.id))
    }

    func testTheSamePathAgainIsARetransmissionNotACopy() {
        let first = beacon(at: 0, via: [])
        let again = beacon(at: 2, via: [])
        XCTAssertTrue(PacketDuplicates.marks(for: [first, again]).isEmpty)
    }

    func testOutsideTheWindowItIsANewFrame() {
        let first = beacon(at: 0, via: [])
        let later = beacon(at: PacketDuplicates.window + 1, via: ["WQ8M-9"])
        XCTAssertTrue(PacketDuplicates.marks(for: [first, later]).isEmpty)
    }
}
