//
//  TalkBanner.swift
//  AXTerm
//
//  The operator's banner for TALK: a caller waiting, with Answer and Not
//  Now, or the chat under way, with End Chat. It stays until dealt with,
//  over every page of the app; the terminal follows the chat.
//

import SwiftUI

struct TalkBanner: View {
    @ObservedObject var router: TalkRouter

    var body: some View {
        VStack(spacing: 6) {
            ForEach(router.pages) { page in
                row(icon: "bubble.left.and.bubble.right.fill",
                    text: TalkBannerText.page(caller: page.caller, door: page.door)) {
                    Button("Answer") { router.answer(page) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(router.chat != nil)
                        .help(router.chat == nil
                              ? "Talk with \(page.caller) on their link. They stay connected; /EX takes them back."
                              : "Finish the chat under way first.")
                    Button("Not Now") { router.decline(page) }
                        .controlSize(.small)
                        .help("\(page.caller) is told nobody is at the station and goes back to the prompt.")
                }
            }
            if let chat = router.chat {
                row(icon: "bubble.left.and.text.bubble.right.fill",
                    text: TalkBannerText.chat(caller: chat.caller)) {
                    Button("End Chat") { router.endChat() }
                        .controlSize(.small)
                        .help("\(chat.caller) goes back \(chat.door == .node ? "to the node" : "to the mailbox").")
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: router.pages)
        .animation(.easeOut(duration: 0.25), value: router.chat)
    }

    private func row<Buttons: View>(icon: String, text: String,
                                    @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .font(.title3)
            Text(text)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 6)
            buttons()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
