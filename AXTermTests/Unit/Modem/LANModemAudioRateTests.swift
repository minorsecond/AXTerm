import XCTest
@testable import AXTerm

/// The rate the modem builds its decoder for, measured from the audio that
/// arrives at start. It counted samples over the whole 0.7 s window, so
/// audio that began part-way through read as a slower rate: on 2026-10-10
/// Warbler reached the IC-705 again 0.4 s before the modem started, a
/// fraction of 48 kHz snapped to 8 kHz, and nothing decoded for 21 and 38
/// minutes. The rate is now samples over the span they arrived in.
final class LANModemAudioRateTests: XCTestCase {

    /// Packets of `samples` every `every` seconds from `start` to `end`.
    private func arrivals(from start: Double, to end: Double, every: Double = 0.02, samples: Int)
        -> [LANModemAudioIO.Arrival] {
        stride(from: start, to: end, by: every).map { .init(at: $0, samples: samples) }
    }

    func testAFullWindowOf48kHzIs48kHz() {
        XCTAssertEqual(LANModemAudioIO.estimateRate(arrivals(from: 0, to: 0.7, samples: 960), configured: 48_000), 48_000)
    }

    func testAudioThatStartsLateIsStillItsOwnRate() {
        // The failure: 48 kHz arriving only in the last 0.1 s of the window.
        XCTAssertEqual(LANModemAudioIO.estimateRate(arrivals(from: 0.45, to: 0.7, samples: 960), configured: 48_000), 48_000)
        XCTAssertEqual(LANModemAudioIO.estimateRate(arrivals(from: 0.55, to: 0.7, samples: 960), configured: 48_000), 48_000)
    }

    func testARadioStreaming16kHzIs16kHz() {
        XCTAssertEqual(LANModemAudioIO.estimateRate(arrivals(from: 0, to: 0.7, samples: 320), configured: 48_000), 16_000)
    }

    /// Too little to measure: the configured rate, as before.
    func testTooLittleAudioFallsBackToTheConfiguredRate() {
        XCTAssertEqual(LANModemAudioIO.estimateRate([], configured: 48_000), 48_000)
        XCTAssertEqual(LANModemAudioIO.estimateRate(arrivals(from: 0.66, to: 0.7, samples: 960), configured: 48_000), 48_000)
    }
}
