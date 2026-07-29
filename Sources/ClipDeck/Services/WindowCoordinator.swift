import AppKit
import Combine
import Foundation

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
            guard let mainWindow = NSApp.windows.first(where: {
                $0.title == "ClipDeck" && !($0 is NSPanel)
            }) else {
                return
            }
            if mainWindow.isMiniaturized {
                mainWindow.deminiaturize(nil)
            }
            mainWindow.makeKeyAndOrderFront(nil)
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
           let keyWindow = NSApp.keyWindow,
           keyWindow.isVisible {
            keyWindow.performClose(nil)
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
