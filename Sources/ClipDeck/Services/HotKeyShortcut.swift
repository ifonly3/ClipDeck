import AppKit
import Carbon

/// A system-wide shortcut stored as a Carbon virtual key code plus modifiers.
struct HotKeyShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    /// What the key showed when it was recorded, on the user's keyboard layout.
    let keyLabel: String

    static let `default` = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(controlKey | optionKey),
        keyLabel: "V"
    )

    var displayString: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyLabel
    }

    enum ValidationError: Error, Equatable {
        /// Plain typing, ⇧/⌥ characters, or a ⌘ command apps already use.
        case interferesWithTyping
        case unsupportedKey
    }

    /// Function keys may stand alone. Anything else needs ⌃, or ⌘ with another
    /// modifier: ⌥V types "√", ⌘V pastes, and neither should become global.
    static func validate(keyCode: UInt32, carbonModifiers: UInt32) -> ValidationError? {
        if functionKeyLabels[keyCode] != nil { return nil }
        if modifierKeyCodes.contains(keyCode) { return .unsupportedKey }
        let hasControl = carbonModifiers & UInt32(controlKey) != 0
        let hasCommand = carbonModifiers & UInt32(cmdKey) != 0
        let otherModifiers = carbonModifiers & UInt32(optionKey | shiftKey | controlKey)
        if hasControl || (hasCommand && otherModifiers != 0) { return nil }
        return .interferesWithTyping
    }

    /// Builds a shortcut from a key press while recording.
    static func make(from event: NSEvent) -> Result<HotKeyShortcut, ValidationError> {
        let keyCode = UInt32(event.keyCode)
        let modifiers = carbonModifiers(from: event.modifierFlags)
        if let error = validate(keyCode: keyCode, carbonModifiers: modifiers) {
            return .failure(error)
        }
        guard let label = keyLabel(keyCode: keyCode, characters: event.charactersIgnoringModifiers) else {
            return .failure(.unsupportedKey)
        }
        return .success(HotKeyShortcut(keyCode: keyCode, carbonModifiers: modifiers, keyLabel: label))
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func keyLabel(keyCode: UInt32, characters: String?) -> String? {
        if let label = functionKeyLabels[keyCode] ?? specialKeyLabels[keyCode] {
            return label
        }
        guard let characters = characters?.trimmingCharacters(in: .whitespacesAndNewlines),
              let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar) else {
            return nil
        }
        return characters.uppercased()
    }

    private static let modifierKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_RightCommand), UInt32(kVK_Shift), UInt32(kVK_RightShift),
        UInt32(kVK_Option), UInt32(kVK_RightOption), UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_CapsLock), UInt32(kVK_Function)
    ]

    private static let functionKeyLabels: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20"
    ]

    private static let specialKeyLabels: [UInt32: String] = [
        UInt32(kVK_Return): "↩", UInt32(kVK_ANSI_KeypadEnter): "⌤", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Space): "Space", UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Escape): "⎋", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓", UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟"
    ]
}
