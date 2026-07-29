import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var store: ClipboardStore
    @EnvironmentObject private var windowCoordinator: WindowCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var hotKeyManager: GlobalHotKeyManager
    @State private var hoveredItemID: ClipboardItem.ID?

    private var recentItems: [ClipboardItem] {
        Array(store.items.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ClipboardWarningsView(
                hotKeyError: hotKeyManager.errorMessage,
                accessStatus: store.accessStatus,
                storageWarning: store.storageWarning,
                captureWarning: store.captureWarning,
                isCompact: true,
                onRetryHotKey: registerHotKey
            )

            recentHistory

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            store.startMonitoring()
            registerHotKey()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("最近剪贴板")
                    .font(.headline)

                Spacer()

                Toggle("记录", isOn: $store.isMonitoring)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityHint(store.isMonitoring ? "关闭后暂停记录新内容" : "打开后开始记录新内容")
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("状态：\(statusText)")
        }
    }

    private var statusText: String {
        if !store.isMonitoring {
            return "记录已暂停"
        }
        if hotKeyManager.errorMessage != nil {
            return "全局快捷键不可用"
        }
        return "全局快捷键：\(GlobalHotKeyManager.shortcutDescription)"
    }

    @ViewBuilder
    private var recentHistory: some View {
        if recentItems.isEmpty {
            Text(store.isMonitoring ? "复制文字或图片后会显示在这里。" : "开启“记录”后开始保存新的内容。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                .multilineTextAlignment(.center)
                .accessibilityLabel(store.isMonitoring ? "暂无剪贴板历史" : "记录已暂停")
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(recentItems) { item in
                        recentItemButton(for: item)
                        .buttonStyle(.plain)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    hoveredItemID == item.id
                                        ? Color.primary.opacity(0.07)
                                        : Color.clear
                                )
                        }
                        .onHover { isHovering in
                            hoveredItemID = isHovering ? item.id : nil
                        }
                        .accessibilityLabel(menuAccessibilityLabel(for: item))
                        .accessibilityHint("复制到系统剪贴板")
                    }
                }
            }
            .frame(maxHeight: 270)
            .accessibilityLabel("最近八条剪贴板历史")
        }
    }

    private var footer: some View {
        HStack {
            Button("打开历史") {
                openHistory()
            }
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityHint("打开可搜索的完整历史窗口")

            settingsControl

            Spacer()

            Button("退出 ClipDeck") {
                NSApp.terminate(nil)
            }
            .accessibilityHint("退出后会清除本次会话的历史")
        }
    }

    private func menuRow(for item: ClipboardItem) -> some View {
        HStack(spacing: 9) {
            menuPreview(for: item)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.menuTitle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.timestampText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.lastCopiedItemID == item.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
    }

    private func recentItemButton(for item: ClipboardItem) -> some View {
        Button(action: { copy(item) }) {
            menuRow(for: item)
        }
    }

    @ViewBuilder
    private func menuPreview(for item: ClipboardItem) -> some View {
        if let image = item.image {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary)

                Image(nsImage: image.thumbnail)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            }
            .frame(width: 38, height: 28)
            .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 38)
                .accessibilityHidden(true)
        }
    }

    private func menuAccessibilityLabel(for item: ClipboardItem) -> String {
        let contentType = item.image == nil ? "文字" : "图片"
        let copiedStatus = store.lastCopiedItemID == item.id ? "，已复制" : ""
        return "\(contentType)，\(item.preview)，\(item.timestampText)\(copiedStatus)"
    }

    private func copy(_ item: ClipboardItem) {
        guard store.copy(item) else {
            announce("复制失败")
            return
        }
        announce(item.image == nil ? "文字已复制" : "图片已复制")
        dismiss()
    }

    private func openHistory() {
        dismiss()
        DispatchQueue.main.async {
            windowCoordinator.presentMainWindow {
                openWindow(id: "main")
            }
        }
    }

    private func registerHotKey() {
        hotKeyManager.register {
            openHistory()
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    @ViewBuilder
    private var settingsControl: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Text("设置…")
            }
        } else {
            Button("设置…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}
