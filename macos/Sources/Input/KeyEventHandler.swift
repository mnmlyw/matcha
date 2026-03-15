import AppKit
import MatchaKit

/// Converts NSEvent to matcha_input_key_s for key event dispatch.
struct KeyEventHandler {
    static func convert(event: NSEvent) -> matcha_input_key_s {
        var key = matcha_input_key_s()
        key.keycode = UInt16(event.keyCode)

        var mods: UInt32 = 0
        if event.modifierFlags.contains(.shift) { mods |= UInt32(MATCHA_MOD_SHIFT) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(MATCHA_MOD_CTRL) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(MATCHA_MOD_ALT) }
        if event.modifierFlags.contains(.command) { mods |= UInt32(MATCHA_MOD_SUPER) }
        key.modifiers = mods

        if let chars = event.characters {
            // Note: the C string pointer is only valid for this scope
            chars.withCString { ptr in
                key.text = ptr
                key.text_len = UInt32(chars.utf8.count)
            }
        }

        return key
    }
}
