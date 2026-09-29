//
//  LinkDebugViewModel.swift
//  AXTerm
//
//  ViewModel for the Link Debug settings tab.
//  Wraps LinkDebugLog with filtering support.
//

import Foundation
import Combine

@MainActor
final class LinkDebugViewModel: ObservableObject {
    @Published var frameFilter: String = ""
    @Published var showTxOnly: Bool = false
    @Published var showRxOnly: Bool = false
    @Published var inputLevel: MobilinkdInputLevel?
    @Published var inputGain: UInt8 = 4
    @Published var isMeasuring: Bool = false

    let log = LinkDebugLog.shared
    private let packetEngine: PacketEngine?
    private var cancellables: Set<AnyCancellable> = []

    init(packetEngine: PacketEngine? = nil) {
        self.packetEngine = packetEngine
        if let engine = packetEngine {
            engine.$mobilinkdInputLevel
                .receive(on: RunLoop.main)
                .assign(to: &$inputLevel)
        }
    }

    /// One-shot measurement. Stops the demodulator briefly, then restarts it.
    func measureInputLevels() {
        isMeasuring = true
        packetEngine?.sendPollInputLevel()
        // Reset measuring state after the RESET is sent (~2s poll + margin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.isMeasuring = false
        }
    }

    func adjustInputLevels() {
        isMeasuring = true
        packetEngine?.sendAdjustInputLevels()
        // Auto-adjust takes ~5s, RESET fires at 5s, give extra margin
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
            self?.isMeasuring = false
        }
    }

    func setInputGain(_ level: UInt8) {
        inputGain = level
        packetEngine?.sendSetInputGain(level)
    }

    var filteredFrames: [LinkDebugFrameEntry] {
        var result = log.frames

        if showTxOnly {
            result = result.filter { $0.direction == .tx }
        } else if showRxOnly {
            result = result.filter { $0.direction == .rx }
        }

        if !frameFilter.isEmpty {
            let query = frameFilter.lowercased()
            result = result.filter { entry in
                entry.frameType.lowercased().contains(query) ||
                entry.rawBytes.hexString.lowercased().contains(query)
            }
        }

        return result
    }

    func clear() {
        log.clear()
    }
}

// MARK: - Data Helpers

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    func truncatedHex(maxBytes: Int = 256) -> String {
        if count <= maxBytes {
            return hexString
        }
        let truncated = prefix(maxBytes)
        return truncated.map { String(format: "%02X", $0) }.joined(separator: " ") + " ..."
    }
}
