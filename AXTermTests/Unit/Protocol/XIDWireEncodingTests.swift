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

/// What AXTerm advertises in its own XID frames. N1 and k are the
/// receiver's limits (AX.25 2.2 §4.3.3.7, §6.3.2): the most it accepts in
/// one information field and the most frames it can take in one window.
/// AXTerm accepts any information field up to 256 bytes and holds half the
/// modulo, so N1 256 and k 4 under modulo 8, whatever K and paclen it uses
/// for its own frames.
@MainActor
final class XIDReceiveCapacityTests: XCTestCase {

    private let peer = AX25Address(call: "W3DWF", ssid: 0)

    /// AXTerm's link defaults with growth off: K 2, paclen 128, no ceilings.
    private func manager() -> AX25SessionManager {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "N0AXT", ssid: 1))
        manager.defaultConfig = AX25SessionConfig(windowSize: 2, paclen: 128, maxRetries: 15,
                                                  rtoMin: 3, rtoMax: 30, initialRto: 4)
        manager.xidMemory = XIDAnswerMemory(defaults: TestDefaults.make("XIDReceiveCapacity"))
        manager.negotiateV22 = true
        return manager
    }

    private func parametersOnTheWire(_ frame: OutboundFrame?) throws -> AX25XIDParameters {
        let frame = try XCTUnwrap(frame)
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: frame.encodeAX25()))
        return try XCTUnwrap(AX25XIDParameters.parse(decoded.info))
    }

    func testTheXIDCommandAdvertisesN1256AndK4() throws {
        let manager = manager()
        let xid = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(xid?.displayInfo, "XID")
        let params = try parametersOnTheWire(xid)
        XCTAssertEqual(params.iFieldLengthRx, 256)
        XCTAssertEqual(params.windowSizeRx, 4)
        XCTAssertTrue(params.supportsSREJ)
    }

    func testTheXIDResponseAdvertisesN1256AndK4() throws {
        let manager = manager()
        var offer = AX25XIDParameters()
        offer.supportsSREJ = true
        offer.iFieldLengthRx = 256
        offer.windowSizeRx = 7
        let response = manager.handleInboundXID(from: peer, path: DigiPath(), radio: .primary,
                                                info: offer.encoded(isCommand: true),
                                                isCommand: true, pf: true).first
        let params = try parametersOnTheWire(response)
        XCTAssertEqual(params.iFieldLengthRx, 256)
        XCTAssertEqual(params.windowSizeRx, 4)
    }

    /// What we advertise does not change what we send: a peer advertising
    /// less than our start still lowers K and paclen to its own limits.
    func testOurOwnSendingLimitsStayIndependentOfTheAdvertisement() {
        let manager = manager()
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        var small = AX25XIDParameters()
        small.supportsSREJ = false
        small.iFieldLengthRx = 64
        small.windowSizeRx = 1
        _ = manager.handleInboundXID(from: peer, path: DigiPath(), radio: .primary,
                                     info: small.encoded(isCommand: false), isCommand: false, pf: true)
        manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.liveWindowSize, 1)
        XCTAssertEqual(session.livePaclen, 64)
        let frames = manager.sendData(Data(repeating: 0x41, count: 200), to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(frames.filter { $0.frameType == "i" }.map(\.payload.count), [64])
    }
}
