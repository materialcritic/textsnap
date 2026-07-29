import AppKit
import Carbon

enum KeyCodes {

    /// Names for keys whose glyph can't be derived from the current keyboard layout.
    private static let special: [UInt16: String] = [
        UInt16(kVK_Return): "\u{21A9}",
        UInt16(kVK_Tab): "\u{21E5}",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "\u{232B}",
        UInt16(kVK_ForwardDelete): "\u{2326}",
        UInt16(kVK_Escape): "\u{238B}",
        UInt16(kVK_Home): "\u{2196}",
        UInt16(kVK_End): "\u{2198}",
        UInt16(kVK_PageUp): "\u{21DE}",
        UInt16(kVK_PageDown): "\u{21DF}",
        UInt16(kVK_LeftArrow): "\u{2190}",
        UInt16(kVK_RightArrow): "\u{2192}",
        UInt16(kVK_UpArrow): "\u{2191}",
        UInt16(kVK_DownArrow): "\u{2193}",
        UInt16(kVK_ANSI_KeypadEnter): "\u{2324}",
        UInt16(kVK_Help): "?\u{20DD}",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20"
    ]

    /// Fallback for the standard ANSI block, used when the layout can't be read.
    private static let ansi: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
        UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
        UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
        UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
        UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Semicolon): ";",
        UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/",
        UInt16(kVK_ANSI_Grave): "`"
    ]

    static func name(for keyCode: UInt16) -> String {
        if let s = special[keyCode] { return s }
        if let s = layoutCharacter(for: keyCode) { return s }
        return ansi[keyCode] ?? "Key \(keyCode)"
    }

    /// Reads the live keyboard layout so a shortcut reads correctly on AZERTY, QWERTZ, etc.
    private static func layoutCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(-50)
            }
            return UCKeyTranslate(layout,
                                  keyCode,
                                  UInt16(kUCKeyActionDisplay),
                                  0, // no modifiers: we want the bare key glyph
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState,
                                  chars.count,
                                  &length,
                                  &chars)
        }

        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length).uppercased()
        return text.isEmpty ? nil : text
    }

    static func modifierString(_ flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "\u{2303}" }
        if flags.contains(.option)  { out += "\u{2325}" }
        if flags.contains(.shift)   { out += "\u{21E7}" }
        if flags.contains(.command) { out += "\u{2318}" }
        return out
    }

    /// Cocoa modifier flags -> Carbon bitfield for `RegisterEventHotKey`.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Rejects combos macOS would swallow or that would trap the user.
    static func isAcceptable(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let functionKey = special[keyCode]?.hasPrefix("F") == true && special[keyCode] != "F"
        if flags.isEmpty && !functionKey { return false }
        if keyCode == UInt16(kVK_Escape) { return false }
        return true
    }
}
