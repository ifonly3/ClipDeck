import AppKit
import SwiftUI

/// A shared settings entry that works from both normal windows and menu-bar popovers.
struct AppSettingsButton: View {
    let title: String
    let systemImage: String?
    var beforeOpen: () -> Void = {}

    var body: some View {
        if #available(macOS 14.0, *) {
            ModernAppSettingsButton(
                title: title,
                systemImage: systemImage,
                beforeOpen: beforeOpen
            )
        } else {
            Button(action: openLegacySettings) {
                settingsLabel
            }
        }
    }

    @ViewBuilder
    private var settingsLabel: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }

    private func openLegacySettings() {
        beforeOpen()
        DispatchQueue.main.async {
            SettingsWindowPresenter.openLegacySettings()
        }
    }
}

@available(macOS 14.0, *)
private struct ModernAppSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    let title: String
    let systemImage: String?
    let beforeOpen: () -> Void

    var body: some View {
        Button(action: open) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
    }

    private func open() {
        beforeOpen()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            SettingsWindowPresenter.bringSettingsForward()
        }
    }
}

@MainActor
private enum SettingsWindowPresenter {
    static func openLegacySettings() {
        NSApp.activate(ignoringOtherApps: true)

        if let settingsItem = NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
        }), let action = settingsItem.action {
            NSApp.sendAction(action, to: settingsItem.target, from: settingsItem)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }

        bringSettingsForward()
    }

    static func bringSettingsForward() {
        DispatchQueue.main.async {
            guard let settingsWindow = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
            }) else {
                return
            }
            if settingsWindow.isMiniaturized {
                settingsWindow.deminiaturize(nil)
            }
            settingsWindow.makeKeyAndOrderFront(nil)
        }
    }
}
