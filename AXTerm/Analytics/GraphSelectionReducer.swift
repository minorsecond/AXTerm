//
//  GraphSelectionReducer.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-23.
//

import Foundation

struct GraphSelectionState: Equatable {
    var selectedIDs: Set<String> = []
    var primarySelectionID: String?

    mutating func normalizePrimary() {
        if let primarySelectionID = primarySelectionID, selectedIDs.contains(primarySelectionID) {
            return
        }
        primarySelectionID = selectedIDs.sorted().first
    }
}

enum GraphSelectionAction: Equatable {
    case clickNode(id: String, isShift: Bool)
    case clickBackground
    case doubleClickNode(id: String, isShift: Bool)
}

enum GraphSelectionEffect: Equatable {
    case none
    case inspect(String)
}

enum GraphSelectionReducer {
    static func reduce(state: inout GraphSelectionState, action: GraphSelectionAction) -> GraphSelectionEffect {
        switch action {
        case let .clickNode(id, isShift):
            applyNodeClick(to: &state, id: id, isShift: isShift)
            return .none
        case .clickBackground:
            state.selectedIDs.removeAll()
            state.primarySelectionID = nil
            return .none
        case let .doubleClickNode(id, isShift):
            applyNodeClick(to: &state, id: id, isShift: isShift)
            return .inspect(id)
        }
    }

    private static func applyNodeClick(to state: inout GraphSelectionState, id: String, isShift: Bool) {
        if isShift {
            state.selectedIDs.insert(id)
        } else {
            state.selectedIDs = [id]
        }
        state.primarySelectionID = id
    }
}
