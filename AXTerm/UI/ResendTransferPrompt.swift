//
//  ResendTransferPrompt.swift
//  AXTerm
//

import Foundation

/// What Send Again asks before a file goes on the air again (home retest
/// findings 5 and 10). Each choice is a protocol the file can go by: the
/// transfer's own, and YAPP too for an AXDP transfer, which a mailbox that
/// takes uploads by YAPP only (an AXTerm from before 2026-10-10) declines.
nonisolated struct ResendTransferPrompt: Equatable {
    struct Option: Equatable {
        let label: String
        let transferProtocol: TransferProtocolType
    }

    let title: String
    let message = "It goes as a new transfer. This one stays in the list as it is."
    let options: [Option]

    init(fileName: String, destination: String, choices: [TransferProtocolType]) {
        title = "Send \(fileName) to \(destination) again?"
        guard let own = choices.first else {
            options = []
            return
        }
        if choices.count == 1 {
            options = [Option(label: "Send Again", transferProtocol: own)]
        } else {
            options = [Option(label: "Send Again by \(own.rawValue)", transferProtocol: own)]
                + choices.dropFirst().map { Option(label: "Send with \($0.rawValue) Instead", transferProtocol: $0) }
        }
    }
}
