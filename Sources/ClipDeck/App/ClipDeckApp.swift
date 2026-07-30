import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
@MainActor
struct ClipDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var clipboardStore = ClipboardStore()
    @StateObject private var hotKeyManager = GlobalHotKeyManager()
    @StateObject private var loginItemManager = LoginItemManager()
    @StateObject private var windowCoordinator = WindowCoordinator()

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
            SettingsView()
                .environmentObject(clipboardStore)
                .environmentObject(loginItemManager)
                .environmentObject(windowCoordinator)
        }
    }

    private var menuBarSystemImage: String {
        if hotKeyManager.errorMessage != nil {
            return "exclamationmark.triangle"
        }
        return clipboardStore.isMonitoring ? "doc.on.clipboard" : "pause.circle"
    }
}
