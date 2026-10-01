//
//  KISSLinkSerialPacingTests.swift
//  AXTermTests
//
//  How a frame is handed to a USB serial TNC. A TNC4 on USB dropped KISS
//  frames longer than one 64-byte USB packet when they came in one write,
//  then reset 8 seconds later; 32-byte pieces 10 ms apart all went out.
//

import XCTest
@testable import AXTerm

final class KISSLinkSerialPacingTests: XCTestCase {
    func testUSBSerialIsPacedInPiecesSmallerThanAUSBPacket() throws {
        let pacing = try XCTUnwrap(KISSLinkSerial.writePacing(isBluetooth: false))
        XCTAssertLessThan(pacing.chunkBytes, 64, "no piece may fill a USB full-speed packet")
        XCTAssertGreaterThan(pacing.gapMicroseconds, 0)
    }

    func testPacingIsFarFasterThanAnyRadioChannel() throws {
        let pacing = try XCTUnwrap(KISSLinkSerial.writePacing(isBluetooth: false))
        let bytesPerSecond = Double(pacing.chunkBytes) / (Double(pacing.gapMicroseconds) / 1_000_000)
        XCTAssertGreaterThan(bytesPerSecond, 9600.0 / 8 * 2, "at least twice a 9600 baud channel")
    }

    func testBluetoothSerialIsNotPaced() {
        XCTAssertNil(KISSLinkSerial.writePacing(isBluetooth: true))
    }

    func testFramesSplitIntoWholePiecesWithNothingLost() {
        let pacing = KISSLinkSerial.writePacing(isBluetooth: false)
        XCTAssertEqual(KISSLinkSerial.writeChunks(18, pacing: pacing), [18], "an RR is one write")
        XCTAssertEqual(KISSLinkSerial.writeChunks(32, pacing: pacing), [32])
        XCTAssertEqual(KISSLinkSerial.writeChunks(81, pacing: pacing), [32, 32, 17])
        XCTAssertEqual(KISSLinkSerial.writeChunks(249, pacing: pacing), [32, 32, 32, 32, 32, 32, 32, 25])
        XCTAssertEqual(KISSLinkSerial.writeChunks(0, pacing: pacing), [])
        for n in 1...600 {
            let pieces = KISSLinkSerial.writeChunks(n, pacing: pacing)
            XCTAssertEqual(pieces.reduce(0, +), n)
            XCTAssertTrue(pieces.allSatisfy { $0 > 0 && $0 <= 32 })
        }
        XCTAssertEqual(KISSLinkSerial.writeChunks(249, pacing: nil), [249])
    }
}

/// The gap between pieces holds across frames, not only inside one.
final class KISSLinkSerialPacingWaitTests: XCTestCase {
    private let pacing = KISSLinkSerial.WritePacing(chunkBytes: 32, gapMicroseconds: 10_000)

    func testTheFirstWriteDoesNotWait() {
        XCTAssertEqual(KISSLinkSerial.pacingWait(lastWriteAt: 0, now: 5_000_000_000, pacing: pacing), 0)
    }

    func testAWriteRightAfterAnotherWaitsTheRestOfTheGap() {
        let last: UInt64 = 1_000_000_000
        XCTAssertEqual(KISSLinkSerial.pacingWait(lastWriteAt: last, now: last, pacing: pacing), 10_000)
        XCTAssertEqual(KISSLinkSerial.pacingWait(lastWriteAt: last, now: last + 4_000_000, pacing: pacing), 6_000)
    }

    func testAWriteAfterTheGapDoesNotWait() {
        let last: UInt64 = 1_000_000_000
        XCTAssertEqual(KISSLinkSerial.pacingWait(lastWriteAt: last, now: last + 10_000_000, pacing: pacing), 0)
        XCTAssertEqual(KISSLinkSerial.pacingWait(lastWriteAt: last, now: last + 900_000_000, pacing: pacing), 0)
    }

    /// An RR, an I-frame and another RR written back to back never put more
    /// than one piece on the wire inside a gap.
    func testBackToBackFramesAreSpacedLikePiecesOfOneFrame() {
        var clock: UInt64 = 2_000_000_000
        var last: UInt64 = 0
        var sends: [UInt64] = []
        for frame in [18, 38, 18] {
            for _ in KISSLinkSerial.writeChunks(frame, pacing: pacing) {
                clock += UInt64(KISSLinkSerial.pacingWait(lastWriteAt: last, now: clock, pacing: pacing)) * 1_000
                sends.append(clock)
                last = clock
                clock += 100_000  // the write itself
            }
        }
        for (a, b) in zip(sends, sends.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 10_000_000)
        }
    }
}
