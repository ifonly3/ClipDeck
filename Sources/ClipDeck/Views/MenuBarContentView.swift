import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var store: ClipboardStore
    @EnvironmentObject private var windowCoordinator: WindowCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var hotKeyManager: GlobalHotKeyManager

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
                onRetryHotKey: { hotKeyManager.retry() },
                beforeOpeningSettings: { dismiss() }
            )

            recentHistory

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            windowCoordinator.registerMainWindowOpener { openWindow(id: "main") }
            windowCoordinator.rememberFrontmostApplication()
            store.startMonitoring()
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
        guard let shortcut = hotKeyManager.shortcutDescription else {
            return L10n.string("全局快捷键已关闭")
        }
        return L10n.string("全局快捷键：%@", shortcut)
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
                        MenuHistoryRow(
                            item: item,
                            isCopied: store.lastCopiedItemID == item.id,
                            height: rowHeight,
                            onCopy: { copy(item) },
                            onCopyPlainText: { copy(item, plainTextOnly: true) },
                            onOpenDetails: { openHistory(selecting: item.id) }
                        )
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

/// One recent item in the menu-bar window. Hover state lives here, so moving
/// the pointer redraws a single row instead of the whole popover.
private struct MenuHistoryRow: View {
    let item: ClipboardItem
    let isCopied: Bool
    let height: CGFloat
    let onCopy: () -> Void
    let onCopyPlainText: () -> Void
    let onOpenDetails: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onCopy) {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(L10n.string("复制到系统剪贴板"))

            Button(action: onOpenDetails) {
                Image(systemName: "arrow.up.right.square")
                    .frame(width: 26, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.string("查看完整内容"))
            .accessibilityLabel(L10n.string("查看详情：%@", item.preview))
        }
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(L10n.string("查看完整内容"), action: onOpenDetails)
            if item.hasRichText {
                Button(L10n.string("复制为纯文本"), action: onCopyPlainText)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 9) {
            preview

            VStack(alignment: .leading, spacing: 2) {
                Text(item.menuTitle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.timestampText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isCopied {
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

    @ViewBuilder
    private var preview: some View {
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

    private var accessibilityLabel: String {
        let copiedStatus = isCopied ? L10n.string("，已复制") : ""
        let label = L10n.string(
            "历史项目：%@，%@，%@%@",
            item.localizedContentType,
            item.preview,
            item.timestampText,
            copiedStatus
        )
        return item.captureNote.map { label + "，" + $0 } ?? label
    }
}

