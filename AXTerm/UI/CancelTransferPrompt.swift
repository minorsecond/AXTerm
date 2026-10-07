import Foundation

/// The question the cancel button asks before it ends a running transfer.
///
/// A canceled transfer cannot be resumed, so one tap on the red button
/// threw away everything sent so far (smoke run 2026-10-03-1, issue 114).
/// It asks while data is moving; a transfer still waiting to start, or
/// paused, has nothing on the air to lose and cancels at once.
nonisolated struct CancelTransferPrompt: Equatable {
    let title: String
    let message: String
    let keepLabel: String
    let cancelLabel = "Cancel Transfer"

    static func isNeeded(for status: BulkTransferStatus) -> Bool {
        switch status {
        case .sending, .awaitingCompletion: return true
        case .pending, .awaitingAcceptance, .paused, .completed, .cancelled, .failed: return false
        }
    }

    init(transfer: BulkTransfer) {
        let receiving = transfer.direction == .inbound
        title = "Cancel \(receiving ? "receiving" : "sending") \(transfer.fileName)?"
        message = "A canceled transfer can't be resumed."
        keepLabel = receiving ? "Keep Receiving" : "Keep Sending"
    }
}
