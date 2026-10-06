//
//  AX25ConnectProgressTests.swift
//  AXTermTests
//
//  How an Auto attempt reads a link it is waiting on. Smoke run
//  2026-10-03-1, issue 88: the direct rung to EPINDB was failed 2 s in as
//  "peer disconnected before session establishment" while its XID was
//  still out (the session reads disconnected until the SABM goes), so the
//  ladder dialed the same station again under K0EPI-3 while the first link
//  came up.
//

import XCTest
@testable import AXTerm

final class AX25ConnectProgressTests: XCTestCase {

    func testAnXIDStillOutIsProgressNotFailure() {
        XCTAssertEqual(AX25ConnectProgress.verdict(
            state: .disconnected, refused: false, negotiating: true, elapsed: 6), .waiting)
    }

    func testDisconnectedAfterTheStartWithNothingOutIsAFailure() {
        guard case .failed = AX25ConnectProgress.verdict(
            state: .disconnected, refused: false, negotiating: false, elapsed: 3) else {
            return XCTFail("a link that fell back to disconnected is not still connecting")
        }
    }

    func testTheFirstMomentsAreProgress() {
        XCTAssertEqual(AX25ConnectProgress.verdict(
            state: .disconnected, refused: false, negotiating: false, elapsed: 1), .waiting)
        XCTAssertEqual(AX25ConnectProgress.verdict(
            state: .connecting, refused: false, negotiating: false, elapsed: 20), .waiting)
    }

    func testConnectedAndRefused() {
        XCTAssertEqual(AX25ConnectProgress.verdict(
            state: .connected, refused: false, negotiating: false, elapsed: 5), .connected)
        XCTAssertEqual(AX25ConnectProgress.verdict(
            state: .disconnected, refused: true, negotiating: false, elapsed: 5), .refused)
    }
}
