//
//  XIDWireEncodingTests.swift
//  AXTermTests
//
//  An XID frame on the wire carries its parameters. AX.25 2.2 §4.3.3.7:
//  the XID information field holds the format identifier, group
//  identifier, group length and the parameter fields. Every other XID test
//  checked the OutboundFrame or the parameter codec; none read the bytes
//  that `encodeAX25()` hands the TNC, which is where the field was lost.
//

import XCTest
@testable import AXTerm

final class XIDWireEncodingTests: XCTestCase {

    private let local = AX25Address(call: "N0AXT", ssid: 1)
    private let peer = AX25Address(call: "W3DWF", ssid: 0)

    private func offer() -> AX25XIDParameters {
        var params = AX25XIDParameters()
        params.supportsSREJ = true
        params.iFieldLengthRx = 128
        params.windowSizeRx = 2
        return params
    }

    /// The command AXTerm sends before its first SABM to a station.
    func testAnXIDCommandCarriesItsParametersOnTheWire() throws {
        let frame = AX25FrameBuilder.buildXID(from: local, to: peer, parameters: offer(), isCommand: true)
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: frame.encodeAX25()))
        XCTAssertEqual(decoded.control, 0xBF, "XID with P set")
        XCTAssertEqual(decoded.info, offer().encoded(isCommand: true),
                       "the information field must reach the TNC")
        let parsed = try XCTUnwrap(AX25XIDParameters.parse(decoded.info))
        XCTAssertTrue(parsed.supportsSREJ)
        XCTAssertEqual(parsed.iFieldLengthRx, 128)
        XCTAssertEqual(parsed.windowSizeRx, 2)
    }

    /// The response AXTerm sends to a station that negotiates with it.
    func testAnXIDResponseCarriesItsParametersOnTheWire() throws {
        let frame = AX25FrameBuilder.buildXID(from: local, to: peer, parameters: offer(),
                                              isCommand: false, pf: true)
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: frame.encodeAX25()))
        XCTAssertEqual(decoded.info, offer().encoded(isCommand: false))
        XCTAssertNil(decoded.pid, "U frames other than UI carry no PID")
    }

    /// Frames without an information field still have none.
    func testSupervisoryAndModeFramesStillCarryNoInformationField() throws {
        let frames = [
            AX25FrameBuilder.buildSABM(from: local, to: peer),
            AX25FrameBuilder.buildUA(from: local, to: peer),
            AX25FrameBuilder.buildDM(from: local, to: peer),
            AX25FrameBuilder.buildDISC(from: local, to: peer),
            AX25FrameBuilder.buildRR(from: local, to: peer, nr: 3)
        ]
        for frame in frames {
            let bytes = frame.encodeAX25()
            XCTAssertEqual(bytes.count, 15, "\(frame.displayInfo ?? ""): addresses and control only")
        }
    }
}
