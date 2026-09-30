//
//  MobilinkdControlling.swift
//  AXTerm
//

import Foundation

nonisolated enum MobilinkdTestTone: String, CaseIterable, Identifiable, Sendable {
    case mark, space, both
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mark: return "1200 Hz"
        case .space: return "2200 Hz"
        case .both: return "Both"
        }
    }

    var frame: [UInt8] {
        switch self {
        case .mark: return MobilinkdTNC.sendMark()
        case .space: return MobilinkdTNC.sendSpace()
        case .both: return MobilinkdTNC.sendBoth()
        }
    }
}

/// What a link is doing with its TNC4 beyond passing packets.
nonisolated enum MobilinkdActivity: Equatable, Sendable {
    case idle
    /// Streaming input levels. The demodulator is off meanwhile.
    case measuring
    /// Sending a test tone, which keeps the radio keyed.
    case sendingTone(MobilinkdTestTone)
    /// A short timed recording for the receive-level tuner, or waiting for
    /// the transmission it starts after. The demodulator is off while the
    /// stream runs.
    case sampling
}

/// Live operations on a connected Mobilinkd TNC4, for the settings page.
///
/// Replies arrive the ordinary way, as telemetry, and land in PacketEngine's
/// `mobilinkdDevices`. Each operation leaves the TNC4 decoding packets again
/// when it ends: measuring and the status read stop the demodulator, and only
/// RESET restarts it.
protocol MobilinkdControlling: AnyObject {
    /// The link's TNC is a Mobilinkd.
    var isMobilinkd: Bool { get }
    var mobilinkdActivity: MobilinkdActivity { get }

    /// Ask for every setting, version and the battery, one query at a time
    /// (see MobilinkdSession.statusRequests for why not GET_ALL_VALUES).
    func refreshMobilinkdStatus()

    /// Stream input levels until `stopMeasuringInput`, or two minutes at most.
    func startMeasuringInput()
    func stopMeasuringInput()

    /// Key the radio with a test tone for at most `seconds`.
    func startTestTone(_ tone: MobilinkdTestTone, for seconds: TimeInterval)
    func stopTestTone()

    /// Write the TNC4's current settings to its flash, so it starts with them
    /// from now on, with every radio. Afterwards there is nothing to put back
    /// when the link closes.
    func saveSettingsToTNC()

    /// Record the input level for a few seconds and hand back every report.
    /// Ends with RESET whenever a stream was started. `completion` runs once,
    /// on the link's queue.
    func sampleInputLevels(_ request: LevelSampleRequest,
                           completion: @escaping @Sendable (LevelSampleResult) -> Void)
    /// End a recording early. Its completion reports `.cancelled`.
    func cancelInputSampling()
}

extension MobilinkdTNC {
    /// Longest a measurement or tone runs if nothing stops it first.
    static let maxMeasuringSeconds: TimeInterval = 120
    static let defaultToneSeconds: TimeInterval = 10
}
