import Foundation

/// The outcome of one Winlink mail exchange session.
nonisolated struct WinlinkExchangeSummary: Equatable, Sendable {
    var sentMIDs: [String] = []
    var receivedMIDs: [String] = []
    var rejectedMIDs: [String] = []
    var deferredMIDs: [String] = []
    var bytesSent: Int = 0
    var bytesReceived: Int = 0
    var aborted: Bool = false
    var failureReason: String?

    var succeeded: Bool { failureReason == nil && !aborted }
}
