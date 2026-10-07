import SwiftUI

/// What a hardware keyboard's Return does in the message field.
///
/// On the iPad, Return did not send: the field's submit and the Send
/// button's Return shortcut both claim the key, and on iPadOS neither sent
/// (smoke run 2026-10-03-1, issue 111). The field takes a plain Return
/// itself. Return with a modifier is left to the system and other shortcuts.
nonisolated enum ComposeReturnKey {
    static func sends(modifiers: EventModifiers, canSend: Bool) -> Bool {
        canSend && modifiers.isEmpty
    }
}
