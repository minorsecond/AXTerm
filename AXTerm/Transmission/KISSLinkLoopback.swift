//
//  KISSLinkLoopback.swift
//  AXTerm
//
//  In-memory loopback link for testing.
//  Data sent via send() is immediately delivered to the delegate.
//

import Foundation

/// In-memory loopback KISS link for unit tests.
///
/// Data written via `send()` is immediately forwarded to the delegate's
/// `linkDidReceive()`, simulating a perfect bidirectional link.
/// Useful for verifying KISS frame encoding/decoding round-trips.
///
/// Marked `@MainActor` because `KISSLinkDelegate` methods are `@MainActor`.
@MainActor
final class KISSLinkLoopback: KISSLink {
    private(set) var state: KISSLinkState = .disconnected
    weak var delegate: KISSLinkDelegate?

    var endpointDescription: String { "loopback" }

    /// All data that has been sent through this link
    private(set) var sentData: [Data] = []

    /// If true, data sent is looped back to the delegate. If false, only recorded.
    var loopbackEnabled: Bool = true

    /// Simulate a specific error on next send
    var simulatedSendError: Error?

    func open() {
        state = .connected
        delegate?.linkDidChangeState(.connected)
    }

    func close() {
        state = .disconnected
        delegate?.linkDidChangeState(.disconnected)
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        sentData.append(data)

        if let error = simulatedSendError {
            simulatedSendError = nil
            completion(error)
            return
        }

        if loopbackEnabled {
            delegate?.linkDidReceive(data)
        }
        completion(nil)
    }

    /// Simulate receiving data from the remote side (inject data as if from TNC)
    func injectReceived(_ data: Data) {
        delegate?.linkDidReceive(data)
    }

    /// Reset recorded data
    func reset() {
        sentData.removeAll()
    }
}
