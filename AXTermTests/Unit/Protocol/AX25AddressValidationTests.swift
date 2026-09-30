//
//  AX25AddressValidationTests.swift
//  AXTermTests
//
//  One test per address rule, both ways round, plus the noise burst that
//  became the station "V},'-11" overnight on 2026-09-29.
//

import XCTest
@testable import AXTerm

final class AX25AddressValidationTests: XCTestCase {

    // MARK: - Helpers

    /// Six callsign bytes from a string, padded with spaces, each shifted.
    private func callBytes(_ call: String) -> [UInt8] {
        let padded = Array(call.utf8) + Array(repeating: 0x20, count: max(0, 6 - call.utf8.count))
        return padded.prefix(6).map { $0 << 1 }
    }

    private func address(_ call: String, ssid: Int = 0, last: Bool = false,
                         hBit: Bool = false, reserved: UInt8 = 0x60) -> [UInt8] {
        var ssidByte = reserved | (UInt8(ssid & 0x0F) << 1)
        if last { ssidByte |= 0x01 }
        if hBit { ssidByte |= 0x80 }
        return callBytes(call) + [ssidByte]
    }

    /// A UI frame from raw address blocks.
    private func frame(_ addresses: [[UInt8]], control: UInt8 = 0x03,
                       tail: [UInt8] = [0xF0, 0x3E, 0x74]) -> Data {
        Data(addresses.flatMap { $0 } + [control] + tail)
    }

    private func check(_ bytes: [UInt8]) -> Result<AX25.AddressDecodeResult, AX25.AddressFault> {
        AX25.checkAddress(data: Data(bytes), offset: 0)
    }

    private func fault(_ bytes: [UInt8]) -> AX25.AddressFault? {
        if case .failure(let f) = check(bytes) { return f }
        return nil
    }

    private func frameFault(_ data: Data) -> AX25.FrameFault? {
        if case .failure(let f) = AX25.checkFrame(ax25: data) { return f }
        return nil
    }

    // MARK: - The overnight noise burst

    /// Raw frame stored at 2026-09-30 10:22 with an HT's squelch open. The old
    /// decoder read it as ";Q,C*B" from "V},'-11", an I-frame.
    static let overnightNoise = Data(hexString:
        "76E359C655C54CEDFB584F2B269689477AF8DA2F06180000000C0000000000000000000000000000000000000000")!

    func testOvernightNoiseIsRefusedWithAReason() {
        XCTAssertNil(AX25.decodeFrame(ax25: Self.overnightNoise))
        // 0x76 >> 1 is ';', the first thing wrong with it.
        XCTAssertEqual(frameFault(Self.overnightNoise),
                       .badAddress(.destination, .invalidCharacter(position: 0, value: 0x3B)))
        XCTAssertEqual(AX25.decodeFailureReason(ax25: Self.overnightNoise),
                       "destination address: invalid character 0x3B at position 1")
    }

    func testOvernightNoiseSourceAloneIsAlsoRefused() {
        // Put a clean destination in front and the noise's own source is
        // still refused: its first byte, 0xED, has bit 0 set, and '}' is not a callsign
        // character either.
        var bytes = [UInt8](Self.overnightNoise)
        bytes.replaceSubrange(0..<7, with: address("APRS"))
        let data = Data(bytes)
        XCTAssertNil(AX25.decodeFrame(ax25: data))
        XCTAssertEqual(frameFault(data), .badAddress(.source, .extensionBitInCallsign(position: 0)))
        XCTAssertEqual(AX25.decodeFailureReason(ax25: data),
                       "source address: extension bit set in callsign at position 1")
    }

    func testOvernightNoiseDigipeaterIsRefused() {
        // And with both clean, the third address ("D#=|M-3") fails too.
        var bytes = [UInt8](Self.overnightNoise)
        bytes.replaceSubrange(0..<14, with: address("APRS") + address("N0CALL"))
        let data = Data(bytes)
        XCTAssertNil(AX25.decodeFrame(ax25: data))
        guard case .badAddress(.digipeater(1), _) = frameFault(data) else {
            return XCTFail("expected digipeater 1 to be at fault, got \(String(describing: frameFault(data)))")
        }
    }

    // MARK: - Rule: bit 0 clear in every callsign byte

    func testExtensionBitInAnyCallsignByteIsRefused() {
        for position in 0..<6 {
            var bytes = address("N0CALL")
            bytes[position] |= 0x01
            XCTAssertEqual(fault(bytes), .extensionBitInCallsign(position: position), "byte \(position)")
        }
    }

    func testExtensionBitInSSIDByteIsAccepted() {
        let result = try? check(address("N0CALL", ssid: 5, last: true)).get()
        XCTAssertEqual(result?.address.display, "N0CALL-5")
        XCTAssertEqual(result?.isLast, true)
    }

    func testExtensionBitOnPaddingIsRefused() {
        // A space with bit 0 set (0x41) is still an extension bit in the call.
        var bytes = address("WIDE1")
        bytes[5] = 0x41
        XCTAssertEqual(fault(bytes), .extensionBitInCallsign(position: 5))
    }

    // MARK: - Rule: A-Z, 0-9 and trailing space only

    func testEveryLegalCharacterIsAccepted() {
        let legal = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        for c in legal {
            let call = String(repeating: c, count: 6)
            XCTAssertEqual((try? check(address(call)).get())?.address.call, call)
        }
    }

    func testEveryOtherCharacterIsRefusedInEveryPosition() {
        let legal = Set((0x41...0x5A).map(UInt8.init) + (0x30...0x39).map(UInt8.init) + [0x20])
        for value in UInt8(0)...UInt8(0x7F) where !legal.contains(value) {
            for position in 0..<6 {
                var bytes = address("N0CALL")
                bytes[position] = value << 1
                XCTAssertEqual(fault(bytes), .invalidCharacter(position: position, value: value),
                               String(format: "0x%02X at %d", value, position))
            }
        }
    }

    func testLowercaseIsRefusedAndNotUppercased() {
        // The old decoder read "n0call" as N0CALL.
        XCTAssertEqual(fault(address("n0call")), .invalidCharacter(position: 0, value: 0x6E))
        XCTAssertEqual(fault(address("N0CALl")), .invalidCharacter(position: 5, value: 0x6C))
    }

    func testPunctuationFromTheOvernightNoiseIsRefused() {
        for c in "},';*#=|-" {
            let value = c.asciiValue!
            XCTAssertEqual(fault(address("AB\(c)")), .invalidCharacter(position: 2, value: value), "\(c)")
        }
    }

    func testTrailingPaddingOfAnyLengthIsAccepted() {
        for length in 1...6 {
            let call = String("K0EPIX".prefix(length))
            XCTAssertEqual((try? check(address(call)).get())?.address.call, call)
        }
    }

    func testLeadingSpaceIsRefused() {
        XCTAssertEqual(fault(address(" N0CAL")), .embeddedSpace(position: 0))
        XCTAssertEqual(fault(address("  X")), .embeddedSpace(position: 0))
    }

    func testEmbeddedSpaceIsRefused() {
        XCTAssertEqual(fault(address("N0 CAL")), .embeddedSpace(position: 2))
        XCTAssertEqual(fault(address("A    B")), .embeddedSpace(position: 1))
    }

    func testAllSpacesIsRefused() {
        XCTAssertEqual(fault(address("")), .emptyCallsign)
    }

    func testTruncatedAddressIsRefused() {
        XCTAssertEqual(fault(Array(address("N0CALL").prefix(6))), .truncated)
        XCTAssertEqual(AX25.checkAddress(data: Data(address("N0CALL")), offset: 1).failureValue, .truncated)
        XCTAssertEqual(AX25.checkAddress(data: Data(address("N0CALL")), offset: -1).failureValue, .truncated)
    }

    // MARK: - Real-world names that must pass

    func testGenericDestinationsAndAliasesAreAccepted() {
        for call in ["APRS", "BEACON", "ID", "CQ", "QST", "MAIL", "NODES", "WIDE1", "WIDE2",
                     "RELAY", "TRACE", "TRACE7", "RFONLY", "NOGATE", "TCPIP", "TCPXX", "GPSLJ",
                     "APZAXT", "APMI06", "APMI0", "APDW18", "APX218", "SIMLA", "PVLY", "NCFPD", "W0NED"] {
            XCTAssertNotNil(try? check(address(call)).get(), call)
        }
    }

    func testMicEDestinationsFromTheCaptureAreAccepted() {
        // Heard off the air overnight.
        for call in ["S9RSVQ", "TPSTYS", "S8UPXR", "S8UQPW", "S9STQV", "S9PSTP", "SYUTYW", "SYSRSQ", "TPPWPV"] {
            XCTAssertEqual((try? check(address(call)).get())?.address.call, call, call)
        }
    }

    func testEveryMicEDestinationCharacterIsAccepted() {
        // APRS 1.01 ch. 10: bytes 1-3 may be 0-9, A-K, L, P-Z; bytes 4-6 may
        // be 0-9, L, P-Z. Every combination of classes, in every position.
        let first = Array("0123456789ABCDEFGHIJKLPQRSTUVWXYZ")
        let rest = Array("0123456789LPQRSTUVWXYZ")
        for a in first {
            for d in rest {
                let call = "\(a)\(a)\(a)\(d)\(d)\(d)"
                XCTAssertEqual((try? check(address(call)).get())?.address.call, call, call)
            }
        }
    }

    func testMicEFramesDecodeWholeWithDigipeaters() throws {
        let raw = frame([address("S9RSVQ"), address("WA0DE", ssid: 9),
                         address("W0NED", hBit: true), address("WIDE1", hBit: true),
                         address("WIDE2", ssid: 1, last: true)],
                        tail: [0xF0] + Array("`pDM\u{1C}\u{1E}\u{1D}#/\"J!}".utf8))
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: raw))
        XCTAssertEqual(decoded.to?.display, "S9RSVQ")
        XCTAssertEqual(decoded.from?.display, "WA0DE-9")
        XCTAssertEqual(decoded.via.map(\.display), ["W0NED", "WIDE1", "WIDE2-1"])
        XCTAssertEqual(decoded.via.map(\.repeated), [true, true, false])
    }

    // MARK: - SSID byte is not judged

    func testEverySSIDByteValueIsAcceptedOnAGoodCallsign() {
        for ssidByte in UInt8(0)...UInt8(0xFF) {
            let bytes = callBytes("K0EPI") + [ssidByte]
            let result = try? check(bytes).get()
            XCTAssertNotNil(result, String(format: "SSID byte 0x%02X", ssidByte))
            XCTAssertEqual(result?.address.ssid, Int((ssidByte >> 1) & 0x0F))
            XCTAssertEqual(result?.address.repeated, ssidByte & 0x80 != 0)
            XCTAssertEqual(result?.isLast, ssidByte & 0x01 != 0)
        }
    }

    func testReservedBitsZeroStillDecodesAFrame() throws {
        let raw = frame([address("CQ", reserved: 0), address("K0EPI", ssid: 3, reserved: 0),
                         address("RELAY", last: true, hBit: true, reserved: 0)])
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: raw))
        XCTAssertEqual(decoded.from?.display, "K0EPI-3")
        XCTAssertEqual(decoded.via.first?.repeated, true)
    }

    // MARK: - Rule: the address field ends properly

    func testDestinationMarkedLastIsRefused() {
        let raw = frame([address("APRS", last: true), address("N0CALL", last: true)])
        XCTAssertEqual(frameFault(raw), .endsAfterDestination)
    }

    func testEightDigipeatersIsAccepted() throws {
        var addresses = [address("APRS"), address("N0CALL")]
        for n in 1...8 { addresses.append(address("DIGI\(n)", ssid: n, last: n == 8, hBit: n < 4)) }
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: frame(addresses)))
        XCTAssertEqual(decoded.via.count, 8)
        XCTAssertEqual(decoded.via.last?.display, "DIGI8-8")
        XCTAssertEqual(decoded.control, 0x03)
        XCTAssertEqual(decoded.pid, 0xF0)
    }

    func testNineDigipeatersIsRefused() {
        var addresses = [address("APRS"), address("N0CALL")]
        for n in 1...9 { addresses.append(address("DIGI\(n)", last: n == 9)) }
        XCTAssertEqual(frameFault(frame(addresses)), .tooManyDigipeaters)
    }

    func testEightDigipeatersWithoutAnEndIsRefused() {
        // The 8th digipeater has no extension bit and valid-looking bytes
        // follow: that would be a 9th address.
        var addresses = [address("APRS"), address("N0CALL")]
        for n in 1...8 { addresses.append(address("DIGI\(n)")) }
        addresses.append(address("MORE", last: true))
        XCTAssertEqual(frameFault(frame(addresses)), .tooManyDigipeaters)
    }

    func testAddressFieldThatRunsOutIsRefused() {
        // Source says more addresses follow, then only 5 bytes remain.
        let raw = Data(address("APRS") + address("N0CALL") + [0x03, 0xF0, 0x41, 0x42, 0x43])
        XCTAssertEqual(frameFault(raw), .unterminatedAddressField(addresses: 2))
        XCTAssertNil(AX25.decodeFrame(ax25: raw))
    }

    func testNoExtensionBitAnywhereIsRefused() {
        var noEOA = Data(repeating: 0xA0, count: 14)  // "PPPPPP" twice, no end
        noEOA.append(contentsOf: [0x03, 0x00])
        XCTAssertEqual(frameFault(noEOA), .unterminatedAddressField(addresses: 2))
    }

    func testMissingControlFieldIsRefused() {
        let raw = Data(address("APRS") + address("N0CALL") + address("WIDE1", ssid: 1, last: true))
        XCTAssertEqual(frameFault(raw), .missingControlField)
    }

    func testBadDigipeaterRefusesTheWholeFrame() {
        // The old decoder stopped at the bad digi and read its first byte as
        // the control field, keeping the frame with a shortened path.
        let raw = frame([address("APRS"), address("N0CALL"), address("WIDE1", ssid: 1),
                         address("wide2", ssid: 1, last: true)])
        XCTAssertEqual(frameFault(raw), .badAddress(.digipeater(2), .invalidCharacter(position: 0, value: 0x77)))
        XCTAssertEqual(AX25.decodeFailureReason(ax25: raw),
                       "digipeater 2 address: invalid character 0x77 at position 1")
    }

    func testSourceSetsExtensionBitWithNoDigipeaters() throws {
        let raw = frame([address("APRS"), address("N0CALL", ssid: 15, last: true)])
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: raw))
        XCTAssertEqual(decoded.via, [])
        XCTAssertEqual(decoded.from?.display, "N0CALL-15")
    }

    func testFramesWithOnlyAControlByteStillDecode() throws {
        // S and U frames carry nothing after the control byte.
        for control: UInt8 in [0x01, 0x41, 0x2F, 0x3F, 0x43, 0x63, 0x73, 0x0F, 0x1F] {
            let raw = Data(address("KB5YZB", ssid: 7) + address("K0EPI", ssid: 1, last: true) + [control])
            let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: raw), String(format: "0x%02X", control))
            XCTAssertEqual(decoded.control, control)
            XCTAssertEqual(decoded.info, Data())
        }
    }

    // MARK: - Digipeater

    func testDigipeaterWillNotRepeatAMalformedFrame() {
        let good = frame([address("APRS"), address("N0CALL", ssid: 9),
                          address("K0EPI", ssid: 1, last: true)])
        XCTAssertNotNil(AX25Digipeater.repeatFrame(good, myAddresses: ["K0EPI-1"]))

        let badSource = frame([address("APRS"), address("N0}ALL", ssid: 9),
                               address("K0EPI", ssid: 1, last: true)])
        XCTAssertNil(AX25Digipeater.repeatFrame(badSource, myAddresses: ["K0EPI-1"]))

        // Our call, then a path that never ends.
        let unterminated = Data(address("APRS") + address("N0CALL") + address("K0EPI", ssid: 1)
                                + [0x03, 0xF0, 0x41])
        XCTAssertNil(AX25Digipeater.repeatFrame(unterminated, myAddresses: ["K0EPI-1"]))

        let wide = frame([address("APRS"), address("N0}ALL"), address("WIDE1", ssid: 1, last: true)])
        XCTAssertNil(AX25Digipeater.repeatWideN(wide, insert: AX25Address(call: "K0EPI", ssid: 1),
                                                fillIn: true, wideAreaMaxHops: 2))
        let wideGood = frame([address("APRS"), address("N0CALL"), address("WIDE1", ssid: 1, last: true)])
        XCTAssertNotNil(AX25Digipeater.repeatWideN(wideGood, insert: AX25Address(call: "K0EPI", ssid: 1),
                                                   fillIn: true, wideAreaMaxHops: 2))
    }

    // MARK: - Slices

    func testDecodesAFrameHeldInADataSlice() throws {
        let whole = Data([0xC0, 0x00]) + frame([address("APRS"), address("N0CALL", last: true)])
        let slice = whole[2...]
        XCTAssertNotEqual(slice.startIndex, 0)
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: slice))
        XCTAssertEqual(decoded.from?.display, "N0CALL")
        XCTAssertEqual(decoded.pid, 0xF0)
        XCTAssertEqual(decoded.info, Data([0x3E, 0x74]))
    }

    // MARK: - Reasons

    func testReasonsNameTheAddressAndTheByte() {
        let cases: [(Data, String)] = [
            (frame([address("A}B"), address("N0CALL", last: true)]),
             "destination address: invalid character 0x7D at position 2"),
            (frame([address("APRS"), address("V},'", ssid: 11, last: true)]),
             "source address: invalid character 0x7D at position 2"),
            (frame([address("APRS"), address("N0 CAL", last: true)]),
             "source address: space inside callsign at position 3"),
            (frame([address("APRS"), address("", last: true)]),
             "source address: empty callsign"),
            (frame([address("APRS", last: true), address("N0CALL", last: true)]),
             "address field ends after destination (extension bit set in its SSID byte)"),
        ]
        for (raw, reason) in cases {
            XCTAssertEqual(AX25.decodeFailureReason(ax25: raw), reason)
        }
    }

    func testSummariesCarryNoByteValues() {
        // The Sentry throttle is keyed on the summary. Two frames that fail
        // the same way at different bytes must share one key.
        let a = frameFault(frame([address("APRS"), address("A}", last: true)]))
        let b = frameFault(frame([address("APRS"), address("ABCD#", last: true)]))
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a?.summary, b?.summary)
        XCTAssertEqual(a?.summary, "source address: invalid character")

        let d1 = frameFault(frame([address("APRS"), address("N0CALL"), address("x", last: true)]))
        let d2 = frameFault(frame([address("APRS"), address("N0CALL"), address("WIDE1"),
                                   address("WIDE2"), address("y", last: true)]))
        XCTAssertEqual(d1?.summary, d2?.summary)
        XCTAssertEqual(d1?.summary, "digipeater address: invalid character")
    }

    func testDecodeAddressAgreesWithCheckAddress() {
        XCTAssertNil(AX25.decodeAddress(data: Data(address("n0call")), offset: 0))
        XCTAssertEqual(AX25.decodeAddress(data: Data(address("N0CALL", ssid: 2)), offset: 0)?.address.display,
                       "N0CALL-2")
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
