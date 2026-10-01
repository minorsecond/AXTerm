//
//  SessionCoordinator+ReceivedText.swift
//  AXTerm
//
//  Saves a marked text download or a Capture the way a received file is
//  saved: in AXTerm Transfers, with a row in the Transfers list.
//

import Foundation

extension SessionCoordinator: ReceivedTextSink {

    /// Writes the text through `ReceivedFileStore` (sanitized name, never
    /// overwriting), adds an inbound Transfers row for it, and posts a line
    /// to the console saying where it went.
    ///
    /// An incomplete download is still saved, under a name that says so, and
    /// its row is marked failed with the reason. On a 1200 baud link the part
    /// that did arrive cost real airtime, and a net script missing its last
    /// lines is still worth reading; the name and the row keep it from
    /// passing for the whole file.
    @discardableResult
    func saveReceivedText(_ text: ReceivedText) -> ReceivedTextReport {
        let fileName = text.problem == nil ? text.name : ReceivedText.incompleteName(for: text.name)
        let path = saveReceivedFile(fileName: fileName, data: text.data)
        let savedName = path.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? ReceivedFileStore.sanitize(fileName)

        var transfer = BulkTransfer(
            id: UUID(),
            fileName: savedName,
            fileSize: text.data.count,
            destination: text.peer,
            chunkSize: 128,
            direction: .inbound,
            transferProtocol: .text,
            compressionSettings: .disabled)
        transfer.setTransmissionSize(text.data.count)
        transfer.markStarted()
        transfer.savedFilePath = path
        transfer.bytesSent = text.data.count
        if path == nil {
            transfer.status = .failed(reason: "The text arrived but could not be saved in \(ReceivedFileStore.folderName).")
        } else if let problem = text.problem {
            transfer.status = .failed(reason: "Incomplete. \(problem)")
        } else {
            transfer.markCompleted()
        }
        transfers.append(transfer)

        let notice = Self.receivedTextNotice(text, savedName: path == nil ? nil : savedName)
        packetEngine?.appendSystemNotification(notice)
        TxLog.inbound(.session, "Received text saved", [
            "peer": text.peer,
            "file": savedName,
            "bytes": text.data.count,
            "complete": text.problem == nil,
            "saved": path != nil
        ])
        return ReceivedTextReport(notice: notice,
                                  savedURL: path.map { URL(fileURLWithPath: $0) },
                                  transferID: transfer.id)
    }

    /// The console line for a saved download or capture.
    nonisolated static func receivedTextNotice(_ text: ReceivedText, savedName: String?,
                                               platform: ReceivedFileStore.Platform = .current) -> String {
        let place = ReceivedFileStore.placeDescription(for: platform)
        guard let savedName else {
            return "\(text.name) from \(text.peer) could not be saved in \(ReceivedFileStore.folderName)."
        }
        switch text.source {
        case .capture(let lines):
            return "Capture of \(text.peer) saved as \"\(savedName)\" (\(lines) \(lines == 1 ? "line" : "lines")) "
                + "in \(place)."
        case .download(let announced):
            if let problem = text.problem {
                return "\(text.name) from \(text.peer) did not arrive complete. \(problem) "
                    + "What arrived is saved as \"\(savedName)\" in \(place)."
            }
            return "Saved \(text.name) from \(text.peer) (\(announced) bytes) as \"\(savedName)\" in \(place)."
        }
    }
}
