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

    private let defaults: UserDefaults
    private var previousApplication: NSRunningApplication?

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

    /// Records the app the user came from, then presents the existing SwiftUI window.
    func presentMainWindow(open: () -> Void) {
        forgetPreviousApplication()
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

    static func isMainWindow(_ window: NSWindow?) -> Bool {
        guard let window, !(window is NSPanel) else {
            return false
        }
        return window.identifier?.rawValue == "main" || window.title == "ClipDeck"
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first(where: { isMainWindow($0) })
    }

    private func rememberFrontmostApplication() {
        guard let candidate = NSWorkspace.shared.frontmostApplication,
              candidate.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              candidate.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        previousApplication = candidate
        previousApplicationName = candidate.localizedName
    }
}
