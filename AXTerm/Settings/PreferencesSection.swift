//
//  PreferencesSection.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/8/26.
//

import SwiftUI

/// A Settings section a deep link can land on.
///
/// A plain `Section` with an `.id` that `SettingsForm` scrolls to when
/// `SettingsRouter.highlightSection` names it.
struct PreferencesSection<Content: View>: View {
    let id: SettingsSection?
    let title: String
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

/// A grouped Settings form that scrolls to the section a deep link names.
///
/// `sections` lists the sections this page holds. When the router's
/// `highlightSection` is one of them, the form takes it (clearing it, so a
/// later visit does not jump) and scrolls it to the top. The work is put on
/// the next turn of the run loop because the router is an `ObservableObject`,
/// and clearing it from inside the update that showed the page is what
/// SwiftUI reports as publishing during a view update.
///
/// A page with a section per radio passes `radios`. A link to that landing
/// scrolls to the section of the radio it names, and the form takes the
/// router's `pendingRadio` as well.
struct SettingsForm<Content: View>: View {
    let sections: Set<SettingsSection>
    let radios: RadioLanding?
    @EnvironmentObject private var router: SettingsRouter
    @ViewBuilder let content: Content

    init(landing sections: Set<SettingsSection>, radios: RadioLanding? = nil,
         @ViewBuilder content: () -> Content) {
        self.sections = sections.union(radios.map { [$0.section] } ?? [])
        self.radios = radios
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form { content }
                .formStyle(.grouped)
                .onAppear { land(proxy) }
                .onChange(of: router.highlightSection) { _, _ in land(proxy) }
        }
    }

    private func land(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard let section = router.consume(sections) else { return }
            var target = AnyHashable(section)
            if let radios, section == radios.section {
                target = radios.anchor(router.consumeRadio())
            }
            // One more turn so a page that has just been pushed has laid out
            // the section before it is asked to scroll there.
            DispatchQueue.main.async {
                withAnimation { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }
}

/// How a page with a section per radio lands a link that names a radio.
struct RadioLanding {
    /// The landing that stands for the per-radio sections.
    let section: SettingsSection
    /// The id to scroll to for the radio a link names, or for none.
    let anchor: (RadioID?) -> AnyHashable
}
