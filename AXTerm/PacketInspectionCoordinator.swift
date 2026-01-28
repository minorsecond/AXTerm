//
//  PacketInspectionCoordinator.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation

struct PacketInspectionCoordinator {
    func inspectSelectedPacket(
        selection: Set<Packet.ID>,
        packets: [Packet]
    ) -> PacketInspectorSelection? {
        guard let packet = PacketSelectionResolver.resolve(selection: selection, in: packets) else {
            return nil
        }
        return PacketInspectorSelection(id: packet.id)
    }
}
