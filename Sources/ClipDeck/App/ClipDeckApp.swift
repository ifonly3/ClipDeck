import AppKit
import SwiftUI

/// The app's composition root. It exists before any scene appears, so services
/// such as the global shortcut never depend on which window opens first.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let privacySettings: CapturePrivacySettings
    let clipboardStore: ClipboardStore
    let hotKeyManager: GlobalHotKeyManager
    let loginItemManager: LoginItemManager
    let windowCoordinator: WindowCoordinator

    private init() {
        privacySettings = CapturePrivacySettings()
        clipboardStore = ClipboardStore(privacySettings: privacySettings)
        hotKeyManager = GlobalHotKeyManager()
        loginItemManager = LoginItemManager()
        windowCoordinator = WindowCoordinator()
    }

    func applicationDidFinishLaunching() {
        let windowCoordinator = windowCoordinator
        hotKeyManager.register {
            windowCoordinator.handleGlobalShortcut()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppEnvironment.shared.applicationDidFinishLaunching()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
@MainActor
struct ClipDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var clipboardStore = AppEnvironment.shared.clipboardStore
    @StateObject private var hotKeyManager = AppEnvironment.shared.hotKeyManager
    @StateObject private var loginItemManager = AppEnvironment.shared.loginItemManager
    @StateObject private var windowCoordinator = AppEnvironment.shared.windowCoordinator
    @StateObject private var privacySettings = AppEnvironment.shared.privacySettings

    var body: some Scene {
        Window("ClipDeck", id: "main") {
            ContentView(hotKeyManager: hotKeyManager)
                .environmentObject(clipboardStore)
                .environmentObject(loginItemManager)
                .environmentObject(windowCoordinator)
        }
        .defaultSize(width: 760, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu(L10n.string("剪贴板")) {
                Button(
                    clipboardStore.isMonitoring
                        ? L10n.string("暂停记录")
                        : L10n.string("开始记录")
                ) {
                    clipboardStore.isMonitoring.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }

        MenuBarExtra {
            MenuBarContentView(hotKeyManager: hotKeyManager)
                .environmentObject(clipboardStore)
                .environmentObject(loginItemManager)
                .environmentObject(windowCoordinator)
        } label: {
            Label("ClipDeck", systemImage: menuBarSystemImage)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(hotKeyManager: hotKeyManager)
                .environmentObject(clipboardStore)
                .environmentObject(loginItemManager)
                .environmentObject(windowCoordinator)
                .environmentObject(privacySettings)
        }
    }

    private var menuBarSystemImage: String {
        if hotKeyManager.errorMessage != nil {
            return "exclamationmark.triangle"
        }
        return clipboardStore.isMonitoring ? "doc.on.clipboard" : "pause.circle"
    }
}
