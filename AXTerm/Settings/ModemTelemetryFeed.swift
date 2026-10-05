//
//  ModemTelemetryFeed.swift
//  AXTerm
//

import Combine
import SwiftUI

/// A radio's live modem telemetry, for the views that show it.
///
/// The modem reports ten times a second. Published on the radio page's view
/// model, every report redrew the whole form, and SwiftUI kept an
/// observation record for each redraw: about 8 MB a minute with the page on
/// screen, and 5 MB a minute after the Settings window was closed, which
/// only hides it (smoke run 2026-10-03-1, issue 13). Here only the level
/// meter and the status rows redraw, and only while one of them is on
/// screen.
@MainActor
final class ModemTelemetryFeed: ObservableObject {
    @Published private(set) var telemetry: ModemTelemetry?

    private let source: AnyPublisher<ModemTelemetry?, Never>
    private var subscription: AnyCancellable?
    private var watchers = 0

    init(source: AnyPublisher<ModemTelemetry?, Never>) {
        self.source = source
    }

    /// A view showing the telemetry came on screen.
    func startWatching() {
        watchers += 1
        guard subscription == nil else { return }
        subscription = source
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self, self.telemetry != value else { return }
                self.telemetry = value
            }
    }

    /// A view showing the telemetry went off screen.
    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        subscription = nil
    }
}

/// Shows `content` with the feed's telemetry and keeps the feed running
/// only while it is on screen.
struct ModemTelemetryReader<Content: View>: View {
    @ObservedObject var feed: ModemTelemetryFeed
    @ViewBuilder let content: (ModemTelemetry?) -> Content

    var body: some View {
        content(feed.telemetry)
            .onAppear { feed.startWatching() }
            .onDisappear { feed.stopWatching() }
    }
}
