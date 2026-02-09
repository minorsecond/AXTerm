//
//  FilterHeaderView.swift
//  AXTerm
//
//  Created by Antigravity on 2/9/26.
//

import Combine
import SwiftUI

struct FilterHeaderView: View {
    @ObservedObject var filterContext: AppFilterContext
    let viewKey: ViewKey
    
    /// Optional flag to indicate if station scope is supported in this view.
    var supportsStationScope: Bool = true
    
    var body: some View {
        HStack(spacing: 8) {
            if let station = filterContext.selectedStation {
                FilterPillView(
                    label: "Station",
                    value: station.display,
                    onDismiss: { filterContext.selectedStation = nil }
                )
                
                if !supportsStationScope {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                        .help("Station scope not supported here (yet)")
                }
            }
            
            let query = filterContext.query(for: viewKey)
            if !query.isEmpty {
                FilterPillView(
                    label: "Search",
                    value: "'\(query)'",
                    onDismiss: { filterContext.setQuery("", for: viewKey) }
                )
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

#Preview {
    let context = AppFilterContext.shared
    context.selectedStation = StationID("K0NTS-7")
    context.setQuery("BBS", for: .packets)
    
    return VStack {
        FilterHeaderView(filterContext: context, viewKey: .packets)
        Spacer()
    }
}
