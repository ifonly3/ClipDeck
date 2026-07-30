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
                Text(L10n.string("最近剪贴板"))
                    .font(.headline)

                Spacer()

                Toggle(L10n.string("记录"), isOn: $store.isMonitoring)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityHint(
                        store.isMonitoring
                            ? L10n.string("关闭后暂停记录新内容")
                            : L10n.string("打开后开始记录新内容")
                    )
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string("状态：%@", statusText))
        }
    }

    private var statusText: String {
        if !store.isMonitoring {
            return L10n.string("记录已暂停")
        }
        if hotKeyManager.errorMessage != nil {
            return L10n.string("全局快捷键不可用")
        }
        return L10n.string(
            "全局快捷键：%@",
            GlobalHotKeyManager.shortcutDescription
        )
    }

    @ViewBuilder
    private var recentHistory: some View {
        if recentItems.isEmpty {
            Text(
                store.isMonitoring
                    ? L10n.string("复制文字或图片后会显示在这里。")
                    : L10n.string("开启“记录”后开始保存新的内容。")
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                .multilineTextAlignment(.center)
                .accessibilityLabel(
                    store.isMonitoring
                        ? L10n.string("暂无剪贴板历史")
                        : L10n.string("记录已暂停")
                )
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
                        .accessibilityHint(L10n.string("复制到系统剪贴板"))
                    }
                }
            }
            .frame(maxHeight: 270)
            .accessibilityLabel(L10n.string("最近八条剪贴板历史"))
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.string("打开历史")) {
                openHistory()
            }
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityHint(L10n.string("打开可搜索的完整历史窗口"))

            AppSettingsButton(
                title: L10n.string("设置…"),
                systemImage: nil,
                beforeOpen: { dismiss() }
            )

            Spacer()

            Button(L10n.string("退出 ClipDeck")) {
                NSApp.terminate(nil)
            }
            .accessibilityHint(L10n.string("退出后会清除本次会话的历史"))
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
        let contentType = item.image == nil ? L10n.string("文字") : L10n.string("图片")
        let copiedStatus = store.lastCopiedItemID == item.id
            ? L10n.string("，已复制")
            : ""
        return L10n.string(
            "历史项目：%@，%@，%@%@",
            contentType,
            item.preview,
            item.timestampText,
            copiedStatus
        )
    }

    private func copy(_ item: ClipboardItem) {
        guard store.copy(item) else {
            announce(L10n.string("复制失败"))
            return
        }
        announce(
            item.image == nil
                ? L10n.string("文字已复制")
                : L10n.string("图片已复制")
        )
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

}
