import AppKit
import SwiftUI
import Testing
@testable import ClipDeck

@Test @MainActor
func menuHistoryKeepsSpaceWhenTheWindowRequestsItsMinimumSize() throws {
    let suiteName = "ClipDeckMenuLayoutTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let pasteboard = NSPasteboard(name: .init(suiteName))
    defer { pasteboard.releaseGlobally() }
    let store = ClipboardStore(pasteboard: pasteboard, startsMonitoring: false,
        performsLegacyCleanup: false, userDefaults: defaults)
    let hotKey = GlobalHotKeyManager(enablesSystemRegistration: false)
    let coordinator = WindowCoordinator(defaults: defaults)

    func minimumHeight() -> CGFloat {
        let controller = NSHostingController(rootView:
            MenuBarContentView(hotKeyManager: hotKey)
                .environmentObject(store)
                .environmentObject(coordinator))
        return controller.sizeThatFits(in: CGSize(width: 360, height: 0)).height
    }

    store.restore(ClipboardItem(text: "First synthetic clipboard item"))
    let singleItemHeight = minimumHeight()
    for index in 2...8 {
        store.restore(ClipboardItem(text: "Synthetic clipboard item \(index)"))
    }
    let eightItemHeight = minimumHeight()
    // Previously both minimum sizes contained only the header and footer:
    // ScrollView had no lower bound and every history row disappeared.
    #expect(eightItemHeight > singleItemHeight + 200)
    #expect(singleItemHeight > 150)
    #expect(eightItemHeight < 500)
    #expect(!hotKey.isRegistered)
}
