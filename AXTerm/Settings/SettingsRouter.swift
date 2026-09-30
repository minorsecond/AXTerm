//
//  SettingsRouter.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/8/26.
//

import SwiftUI
import Combine

/// Central router for managing Settings navigation and deep linking.
/// Injected as an EnvironmentObject into the settings hierarchy.
class SettingsRouter: ObservableObject {
    /// Singleton for easy access from non-SwiftUI contexts (like AppDelegates or menu actions)
    static let shared = SettingsRouter()

    /// Opens the app's settings.
    ///
    /// Supplied by whichever shell is running: on macOS the main window sets
    /// it to open the Settings scene, on iOS the root view sets it to switch
    /// tabs and push the page. Left nil the "Open Settings" button silently
    /// does nothing, which is exactly what happened on iPad before the iOS
    /// shell wired it up.
    var openAction: (() -> Void)?

    // MARK: - State

    /// The currently selected top-level tab
    @Published var selectedTab: SettingsTab = .general

    /// The section a deep link wants shown. The page that holds it scrolls
    /// there and then clears it (`consume(_:)`), so arriving on the page
    /// again later does not jump.
    @Published var highlightSection: SettingsSection?

    /// The radio a deep link wants opened inside the Radios pane. The pane
    /// consumes it on arrival, so the operator lands on that radio's form
    /// rather than on a list they then have to pick from.
    @Published var pendingRadio: RadioID?

    /// Set to show first-run setup (callsign, position, a radio). The main
    /// window of each shell presents it and clears this when it closes.
    @Published var showsSetup = false

    // MARK: - Navigation

    /// Navigate to a settings page, and optionally to one section of it.
    ///
    /// - Parameters:
    ///   - tab: The destination page.
    ///   - section: The section to scroll to, which must be on `tab`.
    ///   - radio: For the Radios page, the radio whose page to open.
    @MainActor
    func navigate(to tab: SettingsTab, section: SettingsSection? = nil, radio: RadioID? = nil) {
        if let radio { pendingRadio = radio }
        if selectedTab != tab { selectedTab = tab }
        if let section, section.tab == tab, highlightSection != section { highlightSection = section }

        // Bring the window to front. Only meaningful where windows exist; a
        // handheld shows one thing at a time and is already frontmost.
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
        openAction?()
    }

    /// Navigate to the one section that holds a setting (see `SettingsHome`).
    @MainActor
    func navigate(to section: SettingsSection, radio: RadioID? = nil) {
        navigate(to: section.tab, section: section, radio: radio)
    }

    /// Take the pending section if it is one of `sections`, clearing it.
    /// Pages call this once they are on screen and can scroll to it.
    @MainActor
    func consume(_ sections: Set<SettingsSection>) -> SettingsSection? {
        guard let section = highlightSection, sections.contains(section) else { return nil }
        highlightSection = nil
        return section
    }

    /// Show first-run setup: the callsign, the station's position and a radio.
    @MainActor
    func presentSetup() {
        if !showsSetup { showsSetup = true }
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }
}

/// Identifiers for top-level pages in the Settings window.
nonisolated enum SettingsTab: Hashable, Sendable, CaseIterable {
    case general
    case notifications
    case radios
    case aprs
    case packetNode
    case bbs
    case winlink
    case advanced
    case linkDebug
}

/// Where a deep link leaves a pushed settings stack (the iOS More tab).
///
/// Pure, so the rules can be tested without a navigation stack.
nonisolated enum SettingsDeepLink {

    /// The stack to show for `target`, given the stack already there.
    ///
    /// - Already showing the target: nothing changes, rather than pushing a
    ///   second copy of the page the operator is looking at.
    /// - The target's first page is already in the stack: back to it, then
    ///   on to the rest, so the back button is not a trail of repeats.
    /// - The stack is on screen: the target is pushed onto it, so Back
    ///   returns to where the operator was.
    /// - The stack was behind another tab: it is replaced, because a stack
    ///   left in a hidden tab is not where the operator thinks they are.
    static func path<Destination: Hashable>(current: [Destination], target: [Destination],
                                            stackIsShowing: Bool) -> [Destination] {
        guard !target.isEmpty else { return current }
        if current.count >= target.count, Array(current.suffix(target.count)) == target {
            return current
        }
        guard stackIsShowing else { return target }
        if let index = current.firstIndex(of: target[0]) {
            return Array(current[..<index]) + target
        }
        return current + target
    }
}
