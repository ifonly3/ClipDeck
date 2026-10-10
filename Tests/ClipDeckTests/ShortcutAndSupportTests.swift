import AppKit
import Carbon
import Foundation
import Testing
@testable import ClipDeck

@Suite struct HotKeyShortcutTests {
    private let control = UInt32(controlKey)
    private let option = UInt32(optionKey)
    private let shift = UInt32(shiftKey)
    private let command = UInt32(cmdKey)
    private let keyV = UInt32(kVK_ANSI_V)

    @Test func combinationsThatBreakTypingOrCommonCommandsAreRejected() {
        #expect(HotKeyShortcut.validate(keyCode: keyV, carbonModifiers: control | option) == nil)
        #expect(HotKeyShortcut.validate(keyCode: keyV, carbonModifiers: command | shift) == nil)
        #expect(HotKeyShortcut.validate(keyCode: keyV, carbonModifiers: control) == nil)
        #expect(HotKeyShortcut.validate(keyCode: UInt32(kVK_F5), carbonModifiers: 0) == nil)

        for modifiers in [0, shift, option, option | shift, command] {
            #expect(HotKeyShortcut.validate(keyCode: keyV, carbonModifiers: modifiers) == .interferesWithTyping)
        }
        #expect(HotKeyShortcut.validate(keyCode: UInt32(kVK_Shift), carbonModifiers: control) == .unsupportedKey)
    }

    @Test func displayUsesTheStandardModifierOrder() {
        #expect(HotKeyShortcut.default.displayString == "⌃⌥V")
        let all = HotKeyShortcut(keyCode: keyV, carbonModifiers: command | shift | option | control, keyLabel: "V")
        #expect(all.displayString == "⌃⌥⇧⌘V")
        #expect(HotKeyShortcut.keyLabel(keyCode: UInt32(kVK_Space), characters: " ") == "Space")
        #expect(HotKeyShortcut.keyLabel(keyCode: UInt32(kVK_F12), characters: nil) == "F12")
        #expect(HotKeyShortcut.keyLabel(keyCode: keyV, characters: "v") == "V")
        #expect(HotKeyShortcut.keyLabel(keyCode: keyV, characters: "\u{16}") == nil)
    }

    @Test @MainActor func shortcutChoicesPersistIncludingTurningItOff() throws {
        let suite = "ClipDeckShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: command | shift, keyLabel: "C")

        let manager = GlobalHotKeyManager(enablesSystemRegistration: false, defaults: defaults)
        #expect(manager.shortcut == .default)
        #expect(manager.updateShortcut(custom) == nil)
        #expect(GlobalHotKeyManager(enablesSystemRegistration: false, defaults: defaults).shortcut == custom)

        manager.updateShortcut(nil)
        let disabled = GlobalHotKeyManager(enablesSystemRegistration: false, defaults: defaults)
        #expect(disabled.shortcut == nil)
        #expect(disabled.shortcutDescription == nil)

        manager.updateShortcut(.default)
        #expect(GlobalHotKeyManager(enablesSystemRegistration: false, defaults: defaults).shortcut == .default)
    }

    @Test @MainActor func unreadableOrUnsafeStoredShortcutsFallBackToTheDefault() throws {
        let suite = "ClipDeckShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data("not json".utf8), forKey: GlobalHotKeyManager.shortcutDefaultsKey)
        #expect(GlobalHotKeyManager.storedShortcut(in: defaults) == .default)

        let unsafe = HotKeyShortcut(keyCode: keyV, carbonModifiers: command, keyLabel: "V")
        defaults.set(try JSONEncoder().encode(unsafe), forKey: GlobalHotKeyManager.shortcutDefaultsKey)
        #expect(GlobalHotKeyManager.storedShortcut(in: defaults) == .default)
    }
}

@Suite struct FileAvailabilityTests {
    @Test func reportsMissingFilesByIndex() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDeckAvailability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let present = directory.appendingPathComponent("present.txt")
        try Data("x".utf8).write(to: present)
        let missing = directory.appendingPathComponent("missing.txt")

        #expect(FileAvailability.check([]) == .init(unavailableIndexes: [], timedOut: false))
        #expect(FileAvailability.check([present, directory]).unavailableIndexes.isEmpty)
        #expect(FileAvailability.check([present, missing]) == .init(unavailableIndexes: [1], timedOut: false))
    }
}
