import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var store: ClipboardStore
    @EnvironmentObject private var windowCoordinator: WindowCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var hotKeyManager: GlobalHotKeyManager
    @State private var hoveredItemID: ClipboardItem.ID?

    private let rowHeight: CGFloat = 48

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
            windowCoordinator.rememberFrontmostApplication()
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
                    ? L10n.string("复制文字、图片或文件后会显示在这里。")
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
                VStack(spacing: 2) {
                    ForEach(recentItems) { item in
                        HStack(spacing: 2) {
                            recentItemButton(for: item)
                                .buttonStyle(.plain)
                                .accessibilityLabel(menuAccessibilityLabel(for: item))
                                .accessibilityHint(L10n.string("复制到系统剪贴板"))

                            Button {
                                openHistory(selecting: item.id)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .frame(width: 26, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(L10n.string("查看完整内容"))
                            .accessibilityLabel(L10n.string("查看详情：%@", item.preview))
                        }
                        .frame(height: rowHeight)
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
                        .contextMenu {
                            Button(L10n.string("查看完整内容")) {
                                openHistory(selecting: item.id)
                            }
                            if item.hasRichText {
                                Button(L10n.string("复制为纯文本")) {
                                    copy(item, plainTextOnly: true)
                                }
                            }
                        }
                    }
                }
            }
            // A menu-bar window may ask for its minimum fitting size. An upper
            // bound alone allows ScrollView to collapse to zero height.
            .frame(height: min(270, CGFloat(recentItems.count) * (rowHeight + 2) - 2))
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
            if let captureNote = item.captureNote {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(captureNote)
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
        } else if let files = item.files, let firstFile = files.references.first {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: firstFile.systemImageName)
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)

                if files.references.count > 1 {
                    Text("\(files.references.count)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.tint, in: Capsule())
                }
            }
            .frame(width: 38, height: 28)
            .accessibilityHidden(true)
        } else {
            Image(systemName: item.systemImageName)
                .foregroundStyle(.secondary)
                .frame(width: 38)
                .accessibilityHidden(true)
        }
    }

    private func menuAccessibilityLabel(for item: ClipboardItem) -> String {
        let copiedStatus = store.lastCopiedItemID == item.id
            ? L10n.string("，已复制")
            : ""
        let label = L10n.string(
            "历史项目：%@，%@，%@%@",
            item.localizedContentType,
            item.preview,
            item.timestampText,
            copiedStatus
        )
        return item.captureNote.map { label + "，" + $0 } ?? label
    }

    private func copy(_ item: ClipboardItem, plainTextOnly: Bool = false) {
        guard store.copy(item, plainTextOnly: plainTextOnly) else {
            announce(L10n.string("复制失败"))
            return
        }
        announce(plainTextOnly ? L10n.string("文字已复制") : item.localizedCopiedAnnouncement)
        if windowCoordinator.closesWindowAfterCopy {
            dismiss()
            windowCoordinator.returnToPreviousApplicationIfNeeded()
        }
    }

    private func openHistory(selecting itemID: ClipboardItem.ID? = nil) {
        dismiss()
        DispatchQueue.main.async {
            windowCoordinator.presentMainWindow(selecting: itemID) {
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
