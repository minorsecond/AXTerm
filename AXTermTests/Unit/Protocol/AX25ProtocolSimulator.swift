//
//  AX25ProtocolSimulator.swift
//  AXTermTests
//
//  A deterministic simulator for AX.25 protocol testing.
//  Simulates RF propagation, including latency, packet loss, reordering, and corruption.
//

import Foundation
import XCTest
@testable import AXTerm

@MainActor
final class AX25SimulatorNode {
    let callsign: AX25Address
    let manager: AX25SessionManager
    weak var simulator: AX25ProtocolSimulator?

    init(callsign: String, ssid: UInt8 = 0) {
        self.callsign = AX25Address(call: callsign, ssid: Int(ssid))
        self.manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0))
        self.manager.localCallsign = self.callsign
        
        self.manager.onSendFrame = { [weak self] frame in
            guard let self = self, let sim = self.simulator else { return }
            sim.transmit(frame: frame, from: self)
        }
    }

    func receive(frame: OutboundFrame) {
        let from = frame.source
        let path = frame.path.normalized
        let channel = frame.channel
        let type = frame.frameType.lowercased()
        let desc = frame.displayInfo ?? ""

        if type == "u" {
            if desc.contains("SABM") {
                if let f = manager.handleInboundSABM(from: from, to: frame.destination, path: path, channel: channel) {
                    manager.onSendFrame?(f)
                }
            } else if desc.contains("UA") {
                manager.handleInboundUA(from: from, path: path, channel: channel)
            } else if desc.contains("DM") {
                manager.handleInboundDM(from: from, path: path, channel: channel)
            } else if desc.contains("DISC") {
                if let f = manager.handleInboundDISC(from: from, path: path, channel: channel) {
                    manager.onSendFrame?(f)
                }
            }
        } else if type == "i" {
            if let f = manager.handleInboundIFrame(
                from: from,
                path: path,
                channel: channel,
                ns: frame.ns ?? 0,
                nr: frame.nr ?? 0,
                pf: false,
                payload: frame.payload
            ) {
                manager.onSendFrame?(f)
            }
        } else if type == "s" {
            if desc.starts(with: "RR") {
                if let f = manager.handleInboundRR(from: from, path: path, channel: channel, nr: frame.nr ?? 0, isPoll: false) {
                    manager.onSendFrame?(f)
                }
            } else if desc.starts(with: "REJ") {
                let frames = manager.handleInboundREJ(from: from, path: path, channel: channel, nr: frame.nr ?? 0)
                for f in frames {
                    manager.onSendFrame?(f)
                }
            }
        }
    }
}

@MainActor
final class AX25ProtocolSimulator {
    var nodes: [String: AX25SimulatorNode] = [:]
    
    // Simulation parameters
    var baseLatency: TimeInterval = 0.05       // 50ms base latency
    var jitter: TimeInterval = 0.02            // +/- 20ms jitter
    var dropProbability: Double = 0.0          // 0.0 to 1.0
    var duplicateProbability: Double = 0.0     // 0.0 to 1.0
    var corruptionProbability: Double = 0.0    // 0.0 to 1.0

    /// Deterministic RNG (SplitMix64). Unseeded randomness made lossy-link tests
    /// flaky by design (~1 failure per thousand runs); a fixed seed keeps loss
    /// patterns realistic AND reproducible, per the project's determinism rule.
    private var rngState: UInt64 = 0x5EED_5EED_5EED_5EED

    private func nextRandom() -> UInt64 {
        rngState &+= 0x9E37_79B9_7F4A_7C15
        var z = rngState
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private func randomUnit() -> Double {
        Double(nextRandom() >> 11) / Double(1 << 53)
    }

    private func randomDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + randomUnit() * (range.upperBound - range.lowerBound)
    }

    private func randomInt(below bound: Int) -> Int {
        bound > 0 ? Int(nextRandom() % UInt64(bound)) : 0
    }
    
    func addNode(_ node: AX25SimulatorNode) {
        nodes[node.callsign.display] = node
        node.simulator = self
    }
    
    func transmit(frame: OutboundFrame, from sourceNode: AX25SimulatorNode) {
        // Broadcast to all other nodes (like RF)
        for (call, targetNode) in nodes where call != sourceNode.callsign.display {
            scheduleDelivery(frame: frame, to: targetNode)
        }
    }
    
    private func scheduleDelivery(frame: OutboundFrame, to targetNode: AX25SimulatorNode) {
        // Apply Drop
        if randomUnit() < dropProbability {
            return
        }
        
        // Calculate latency
        let latency = max(0.001, baseLatency + randomDouble(in: -jitter...jitter))
        
        // Corrupt frame
        var frameToDeliver = frame
        if randomUnit() < corruptionProbability {
            frameToDeliver = corrupt(frame: frameToDeliver)
        }
        
        // Schedule delivery
        Task {
            try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
            if !Task.isCancelled {
                targetNode.receive(frame: frameToDeliver)
            }
        }
        
        // Apply Duplication
        if randomUnit() < duplicateProbability {
            let dupLatency = latency + randomDouble(in: 0...0.05)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(dupLatency * 1_000_000_000))
                if !Task.isCancelled {
                    targetNode.receive(frame: frameToDeliver)
                }
            }
        }
    }
    
    private func corrupt(frame: OutboundFrame) -> OutboundFrame {
        guard !frame.payload.isEmpty else { return frame }
        var corruptedData = frame.payload
        // Flip a random bit in a random byte
        let byteIndex = randomInt(below: corruptedData.count)
        let bitIndex = randomInt(below: 8)
        corruptedData[byteIndex] ^= (1 << bitIndex)
        
        return OutboundFrame(
            id: frame.id,
            channel: frame.channel,
            destination: frame.destination,
            source: frame.source,
            path: frame.path,
            createdAt: frame.createdAt,
            payload: corruptedData,
            priority: frame.priority,
            frameType: frame.frameType,
            pid: frame.pid,
            sessionId: frame.sessionId,
            axdpMessageId: frame.axdpMessageId,
            controlByte: frame.controlByte,
            ns: frame.ns,
            nr: frame.nr,
            displayInfo: frame.displayInfo,
            isUserPayload: frame.isUserPayload,
            isCommand: frame.isCommand
        )
    }
}
