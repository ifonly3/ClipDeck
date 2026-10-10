import AppKit
import Combine
import Foundation

extension Notification.Name {
    static let clipDeckMainWindowPresented = Notification.Name(
        "com.qiaoni.clipdeck.main-window-presented"
    )
}

/// Owns the small AppKit boundary needed to return focus after choosing history.
@MainActor
final class WindowCoordinator: ObservableObject {
    static let closesWindowAfterCopyDefaultsKey =
        "com.qiaoni.ClipDeck.closesWindowAfterCopy"

    @Published var closesWindowAfterCopy: Bool {
        didSet {
            guard closesWindowAfterCopy != oldValue else {
                return
            }
            defaults.set(
                closesWindowAfterCopy,
                forKey: Self.closesWindowAfterCopyDefaultsKey
            )
        }
    }

    @Published private(set) var previousApplicationName: String?
    private(set) var requestedItemID: ClipboardItem.ID?
    private(set) var presentationID = UUID()

    private let defaults: UserDefaults
    private var previousApplication: NSRunningApplication?
    private var mainWindowOpener: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.closesWindowAfterCopyDefaultsKey) == nil {
            self.closesWindowAfterCopy = true
        } else {
            self.closesWindowAfterCopy = defaults.bool(
                forKey: Self.closesWindowAfterCopyDefaultsKey
            )
        }
    }

    /// Views that can open SwiftUI windows hand over their `openWindow` action,
    /// so the global shortcut works whichever surface appeared first.
    func registerMainWindowOpener(_ opener: @escaping () -> Void) {
        mainWindowOpener = opener
    }

    /// The global shortcut toggles history: it opens the window, or closes it
    /// and returns to the previous app when the window is already in front.
    func handleGlobalShortcut() {
        if NSApp.isActive, let mainWindow = Self.mainWindow, mainWindow.isVisible, mainWindow.isKeyWindow {
            returnToPreviousApplication(closeKeyWindow: true)
            return
        }
        presentMainWindow(open: mainWindowOpener ?? Self.openMainWindowThroughWindowMenu)
    }

    /// Fallback before any SwiftUI view has appeared: SwiftUI lists the window
    /// in the Window menu, and choosing that item opens it again.
    private static func openMainWindowThroughWindowMenu() {
        guard mainWindow == nil else { return }
        let menuItems = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
        guard let item = menuItems.first(where: {
            $0.title == "ClipDeck" && $0.submenu == nil && $0.action != nil
        }), let action = item.action else {
            return
        }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    /// Records the app the user came from, then presents the existing SwiftUI window.
    func presentMainWindow(selecting itemID: ClipboardItem.ID? = nil, open: () -> Void) {
        presentationID = UUID()
        requestedItemID = itemID
        rememberFrontmostApplication()
        open()
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            guard let mainWindow = Self.mainWindow else {
                return
            }
            if mainWindow.isMiniaturized {
                mainWindow.deminiaturize(nil)
            }
            mainWindow.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .clipDeckMainWindowPresented, object: mainWindow)
        }
    }

    /// Closes the active ClipDeck surface and returns to the app used before ClipDeck.
    func returnToPreviousApplicationIfNeeded() {
        guard closesWindowAfterCopy else {
            return
        }

        returnToPreviousApplication(closeKeyWindow: true)
    }

    func returnToPreviousApplication(closeKeyWindow: Bool = true) {
        let applicationToRestore = previousApplication
        forgetPreviousApplication()

        if closeKeyWindow,
           let mainWindow = Self.mainWindow,
           mainWindow.isVisible {
            mainWindow.performClose(nil)
        }

        if let applicationToRestore,
           !applicationToRestore.isTerminated {
            applicationToRestore.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func forgetPreviousApplication() {
        previousApplication = nil
        previousApplicationName = nil
    }

    func takeRequestedItemID() -> ClipboardItem.ID? {
        defer { requestedItemID = nil }
        return requestedItemID
    }

    static func isMainWindow(_ window: NSWindow?) -> Bool {
        guard let window, !(window is NSPanel) else {
            return false
        }
        return window.identifier?.rawValue == "main" || window.title == "ClipDeck"
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first(where: { isMainWindow($0) })
    }

    func rememberFrontmostApplication() {
        guard let candidate = NSWorkspace.shared.frontmostApplication,
              candidate.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              candidate.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        previousApplication = candidate
        previousApplicationName = candidate.localizedName
    }
}
