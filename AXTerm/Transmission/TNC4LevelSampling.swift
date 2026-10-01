//
//  TNC4LevelSampling.swift
//  AXTerm
//
//  Short, timed recordings of a TNC4's input level, for receive-level
//  calibration and the drift watch (Radio/ReceiveLevel). The link's
//  MobilinkdSessionDriver takes the recording; this file holds what it is
//  asked for and what it hands back.
//

import Foundation

/// One input level report from a TNC4's level stream.
///
/// The firmware sends one report per 30 ADC blocks of 88 samples at 26.4 kHz
/// in 1200 baud mode, so about ten a second (tnc4-firmware AudioInput.cpp,
/// streamLevels). Each covers the 100 ms before it.
nonisolated struct TNC4LevelSample: Codable, Equatable, Sendable {
    /// Seconds from the recording's reference point (see LevelSampleResult).
    var t: Double
    var vpp: Int
    var vmin: Int
    var vmax: Int

    static let fullScale = MobilinkdInputLevel.fullScale

    init(t: Double, vpp: Int, vmin: Int, vmax: Int) {
        self.t = t
        self.vpp = vpp
        self.vmin = vmin
        self.vmax = vmax
    }

    init(t: Double, level: MobilinkdInputLevel) {
        self.init(t: t, vpp: Int(level.vpp), vmin: Int(level.vmin), vmax: Int(level.vmax))
    }

    /// Peak to peak as a share of the ADC's range.
    var fraction: Double { Double(vpp) / Double(Self.fullScale) }

    /// The input touched an end of the ADC's range. The same test the level
    /// meter and the level assistant use.
    var clipped: Bool { vmin == 0 || vmax >= MobilinkdInputLevel.topRail }
}

/// What to record.
nonisolated struct LevelSampleRequest: Equatable, Sendable {
    enum Start: Equatable, Sendable {
        /// Start streaming at once.
        case now
        /// Wait for the next KISS data frame written to the link, estimate
        /// when the TNC4 finishes sending it, and start streaming `delay`
        /// seconds after that. Give up if no frame is written within
        /// `armTimeout`.
        ///
        /// The stream must not be running when the TNC4 starts or ends a
        /// transmission: both post to its audio task, which ends the stream
        /// (tnc4-firmware HDLCEncoder.hpp posts IDLE at key-up and DEMODULATOR
        /// at unkey).
        case afterNextTransmission(timing: KISSTimingParameters, delay: TimeInterval,
                                   armTimeout: TimeInterval)
    }

    var start: Start
    /// How long to stream once started.
    var duration: TimeInterval

    static func now(for duration: TimeInterval) -> LevelSampleRequest {
        LevelSampleRequest(start: .now, duration: duration)
    }
}

/// What a recording produced, however it ended. The TNC4 has been sent RESET
/// whenever a stream was started, except when the link went down, where a new
/// connection restarts the demodulator by itself.
nonisolated struct LevelSampleResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Ran for the whole duration.
        case completed
        /// Stopped on request.
        case cancelled
        /// The link went down.
        case disconnected
        /// Another frame went out mid-recording, or a setting changed. The
        /// samples before that are kept.
        case interrupted
        /// Waited for a transmission and none came.
        case noTransmission
        /// The TNC4 was busy with something else (a measurement, a tone, the
        /// connect sequence), or the link isn't a Mobilinkd.
        case unavailable
    }

    var outcome: Outcome
    /// Oldest first. `t` counts from the estimated end of the transmission
    /// for `.afterNextTransmission`, and from when the stream was asked for
    /// otherwise.
    var samples: [TNC4LevelSample]
    /// How many times the stream stopped by itself and was asked for again.
    var restarts: Int = 0

    static func unavailable() -> LevelSampleResult {
        LevelSampleResult(outcome: .unavailable, samples: [])
    }
}

nonisolated enum TNC4Airtime {
    /// A guess at how long the Bluetooth or USB hop takes before the TNC4
    /// has the frame. Generous; a late start costs 0.1 s of the window.
    static let linkLatency: TimeInterval = 0.1

    /// How long a TNC4 keys the radio for one frame on a clear channel.
    ///
    /// TX delay of flags first (HDLCEncoder::send_delay turns the KISS value
    /// into flag bytes at 1.25 bytes per 10 ms at 1200 bps, which comes out at
    /// the TX delay itself), then the frame with its CRC and a flag at each
    /// end, with 5% for bit stuffing, then the tail.
    static func transmitSeconds(frameBytes: Int, timing: KISSTimingParameters,
                                baud: Double = 1200) -> TimeInterval {
        let preamble = Double(max(0, timing.txDelayMs)) / 1000
        let bits = Double(max(0, frameBytes) + 4) * 8 * 1.05
        let tail = Double(max(0, timing.txTailMs)) / 1000
        return preamble + bits / baud + tail
    }

    /// The AX.25 bytes of each KISS data frame (command nibble 0) in `data`,
    /// unescaped. Hardware frames and the rest are skipped.
    static func dataFrameLengths(in data: Data) -> [Int] {
        var lengths: [Int] = []
        var inFrame = false
        var command: UInt8?
        var count = 0
        var escaped = false
        for byte in data {
            if byte == 0xC0 {
                if inFrame, let command, command & 0x0F == 0, count > 0 { lengths.append(count) }
                inFrame = true
                command = nil
                count = 0
                escaped = false
                continue
            }
            guard inFrame else { continue }
            if command == nil { command = byte; continue }
            if escaped { escaped = false; count += 1; continue }
            if byte == 0xDB { escaped = true; continue }
            count += 1
        }
        return lengths
    }
}
