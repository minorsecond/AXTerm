//
//  LANModemAudioPCMTests.swift
//  AXTermTests
//
//  The last step before transmit audio leaves for the radio. It had no test,
//  and a fault here is silent in the worst way: the transmitter keys, the
//  carrier goes up, and nothing modulates it.
//
//  Every case compares against the byte-at-a-time loop that shipped before
//  the vDSP rewrite, because "behaviour is unchanged" was the claim made for
//  that change and this is the part of it that reaches the air.
//

import XCTest
import Accelerate
@testable import AXTerm

final class LANModemAudioPCMTests: XCTestCase {

    /// The implementation this replaced, verbatim.
    private func legacyPCM(_ samples: [Float], written: Int) -> Data {
        let frames = samples.count
        var out = [UInt8](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = i < written ? max(-1, min(1, samples[i])) : 0
            let s = Int16(v * 32767)
            out[2 * i] = UInt8(truncatingIfNeeded: s)
            out[2 * i + 1] = UInt8(truncatingIfNeeded: s >> 8)
        }
        return Data(out)
    }

    private func encode(_ samples: [Float], written: Int) -> Data {
        var s = samples
        var staging = [Int16]()
        return LANModemAudioIO.encodePCM(&s, written: written, staging: &staging)
    }

    private func assertMatchesLegacy(_ samples: [Float], written: Int,
                                     _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(encode(samples, written: written), legacyPCM(samples, written: written),
                       what, file: file, line: line)
    }

    func testFullScaleSineMatchesTheLoopItReplaced() {
        let frames = 320                      // 20 ms at the 16 kHz an IC-705 streams
        let samples = (0..<frames).map { sinf(2 * .pi * 1200 * Float($0) / 16_000) * 0.9 }
        assertMatchesLegacy(samples, written: frames, "a full 20 ms of modulated audio")
    }

    func testValuesBeyondFullScaleClipTheSameWay() {
        let samples: [Float] = [-3, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 3]
        assertMatchesLegacy(samples, written: samples.count, "clipping")
    }

    func testAPartialRenderZeroesTheTail() {
        let samples = (0..<64).map { _ in Float.random(in: -1...1) }
        assertMatchesLegacy(samples, written: 20, "tail past `written`")
    }

    func testAnEmptyRenderIsSilenceNotGarbage() {
        let samples = (0..<64).map { _ in Float.random(in: -1...1) }
        let data = encode(samples, written: 0)
        XCTAssertEqual(data.count, 128)
        XCTAssertTrue(data.allSatisfy { $0 == 0 }, "nothing rendered must send silence")
        assertMatchesLegacy(samples, written: 0, "empty render")
    }

    /// The regression this file exists for: real modulator output must arrive
    /// as audible PCM, not as zeros.
    func testModulatedAudioIsNotSilent() {
        let frames = 320
        let samples = (0..<frames).map { sinf(2 * .pi * 1200 * Float($0) / 16_000) * 0.5 }
        let data = encode(samples, written: frames)

        XCTAssertEqual(data.count, frames * 2)
        let peak = data.withUnsafeBytes { raw -> Int in
            let i16 = raw.bindMemory(to: Int16.self)
            return i16.reduce(0) { max($0, abs(Int($1))) }
        }
        XCTAssertGreaterThan(peak, 8_000, "a half-scale tone must survive as half-scale PCM")
    }

    /// Byte order is the radio's, not the host's idea of it.
    func testSamplesAreLittleEndian() {
        var samples: [Float] = [0.5]
        var staging = [Int16]()
        let data = LANModemAudioIO.encodePCM(&samples, written: 1, staging: &staging)
        let expected = Int16(Float(0.5) * 32767)
        XCTAssertEqual(data.count, 2)
        XCTAssertEqual(data[0], UInt8(truncatingIfNeeded: expected))
        XCTAssertEqual(data[1], UInt8(truncatingIfNeeded: expected >> 8))
    }

    /// The staging buffer is reused across 20 ms ticks and resized when the
    /// radio's rate changes. A stale size must not truncate or pad the frame.
    func testStagingBufferIsResizedWithTheFrame() {
        var staging = [Int16](repeating: 0, count: 960)   // 48 kHz's worth
        var samples = [Float](repeating: 0.25, count: 320)
        let data = LANModemAudioIO.encodePCM(&samples, written: 320, staging: &staging)
        XCTAssertEqual(staging.count, 320)
        XCTAssertEqual(data.count, 640, "20 ms at 16 kHz is 640 bytes")
    }
}
