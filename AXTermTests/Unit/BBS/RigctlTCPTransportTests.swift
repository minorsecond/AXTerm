//
//  RigctlTCPTransportTests.swift
//  AXTermTests
//
//  The rigctl client against a real TCP server on this Mac. A get is
//  answered with bare values and no end mark, so the reply ends when the
//  line goes quiet; on the road the client waited for ever there, and QRG
//  never answered (remote access test 2026-10-11).
//

import Network
import XCTest
@testable import AXTerm

final class RigctlTCPTransportTests: XCTestCase {

    /// A rigctld that answers `f` with a frequency and anything else with
    /// RPRT 0, and keeps the connection open, as rigctld does.
    private final class FakeRigctld: @unchecked Sendable {
        let listener: NWListener
        private var connections: [NWConnection] = []

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.connections.append(connection)
                connection.start(queue: .global())
                self?.serve(connection)
            }
        }

        func start() async throws -> Int {
            let ready = OnceFlag()
            return try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { [listener] state in
                    switch state {
                    case .ready:
                        if ready.claim() { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                    case .failed(let error):
                        if ready.claim() { continuation.resume(throwing: error) }
                    default: break
                    }
                }
                listener.start(queue: .global())
            }
        }

        private func serve(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, done, _ in
                if let data, let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) {
                    let reply = line == "f" ? "145650000\n" : "RPRT 0\n"
                    connection.send(content: Data(reply.utf8), completion: .idempotent)
                }
                if !done { self?.serve(connection) }
            }
        }

        func stop() {
            listener.cancel()
            connections.forEach { $0.cancel() }
        }
    }

    func testAGetEndsWhenTheLineGoesQuiet() async throws {
        let rig = try FakeRigctld()
        let port = try await rig.start()
        defer { rig.stop() }
        let started = Date()
        let reply = try await RigctlTCPTransport().exchange(host: "127.0.0.1", port: port, line: "f")
        XCTAssertEqual(reply, ["145650000"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testASetEndsAtItsReport() async throws {
        let rig = try FakeRigctld()
        let port = try await rig.start()
        defer { rig.stop() }
        let reply = try await RigctlTCPTransport().exchange(host: "127.0.0.1", port: port, line: "F 145650000")
        XCTAssertEqual(reply, ["RPRT 0"])
    }

    func testNobodyListeningFailsQuickly() async {
        let started = Date()
        do {
            _ = try await RigctlTCPTransport().exchange(host: "127.0.0.1", port: 9, line: "f")
            XCTFail("nothing listens on port 9")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}
