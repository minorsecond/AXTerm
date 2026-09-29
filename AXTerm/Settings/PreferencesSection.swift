//
//  PreferencesSection.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/8/26.
//

import SwiftUI

/// A container for Settings preferences that supports deep linking and highlighting.
///
/// Wraps standard Form Sections but adds an `.id()` for ScrollViewReader
/// and a visual highlight effect controlled by `SettingsRouter`.
struct PreferencesSection<Content: View>: View {
    let id: SettingsSection?
    let title: String
    @EnvironmentObject var router: SettingsRouter
    @ViewBuilder let content: Content
    
    init(_ title: String, id: SettingsSection? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.id = id
        self.content = content()
    }
    
    var body: some View {
        if let id = id {
            Section(title) {
                content
            }
            .id(id)
        } else {
            Section(title) {
                content
            }
        }
    }
}
