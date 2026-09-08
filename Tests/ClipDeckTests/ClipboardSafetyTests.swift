import AppKit
import Foundation
import Testing
@testable import ClipDeck

@Test @MainActor
func monitoringReadsWithoutChangingTheSystemClipboard() throws {
    let pasteboard = safetyTestPasteboard()
    let defaults = try safetyTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )

    let currentText = "This must remain on the clipboard"
    pasteboard.clearContents()
    #expect(pasteboard.setString(currentText, forType: .string))
    let changeCountBeforePolling = pasteboard.changeCount

    store.pollPasteboard()

    #expect(pasteboard.changeCount == changeCountBeforePolling)
    #expect(pasteboard.string(forType: .string) == currentText)
    #expect(store.items.first?.text == currentText)
}

@Test @MainActor
func clearingHistoryDoesNotClearTheSystemClipboard() throws {
    let pasteboard = safetyTestPasteboard()
    let defaults = try safetyTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )

    pasteboard.clearContents()
    #expect(pasteboard.setString("history item", forType: .string))
    store.pollPasteboard()
    #expect(!store.items.isEmpty)

    let currentText = "current clipboard content"
    pasteboard.clearContents()
    #expect(pasteboard.setString(currentText, forType: .string))
    let changeCountBeforeClearingHistory = pasteboard.changeCount

    store.clearHistory()

    #expect(store.items.isEmpty)
    #expect(pasteboard.changeCount == changeCountBeforeClearingHistory)
    #expect(pasteboard.string(forType: .string) == currentText)
}

@MainActor
private func safetyTestPasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("ClipDeckSafetyTests.\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    return pasteboard
}

private func safetyTestDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "ClipDeckSafetyTests.defaults.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(true, forKey: "monitoring")
    return (defaults, suiteName)
}
