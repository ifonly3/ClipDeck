import AppKit
import SwiftUI

struct ContentView: View {
    private enum FocusArea: Hashable {
        case search
        case history
    }

    @EnvironmentObject private var store: ClipboardStore
    @EnvironmentObject private var windowCoordinator: WindowCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @ObservedObject var hotKeyManager: GlobalHotKeyManager

    @State private var searchText = ""
    /// Filtered once per search or history change instead of on every render.
    @State private var cachedVisibleItems: [ClipboardItem]?
    @State private var selectedItemID: ClipboardItem.ID?
    @State private var searchFocusRequestID = UUID()
    @State private var handledPresentationID: UUID?
    @FocusState private var focusedArea: FocusArea?

    private var visibleItems: [ClipboardItem] {
        cachedVisibleItems ?? store.filteredItems(matching: searchText)
    }

    private var selectedItem: ClipboardItem? {
        guard let selectedItemID else {
            return nil
        }
        return visibleItems.first { $0.id == selectedItemID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ClipboardWarningsView(
                hotKeyError: hotKeyManager.errorMessage,
                accessStatus: store.accessStatus,
                storageWarning: store.storageWarning,
                captureWarning: store.captureWarning,
                isCompact: false,
                onRetryHotKey: { hotKeyManager.retry() }
            )

            Divider()

            if visibleItems.isEmpty {
                EmptyStateView(
                    isSearching: !ClipboardSearchQuery(searchText).isEmpty,
                    isMonitoring: store.isMonitoring,
                    onClearSearch: clearSearch,
                    onStartMonitoring: { store.isMonitoring = true }
                )
            } else {
                historyBrowser
            }
        }
        .frame(minWidth: 620, minHeight: 440)
        .background {
            WindowKeyboardBridge(onEscape: handleEscape)
            .frame(width: 0, height: 0)
        }
        .confirmationDialog(
            L10n.string("清空所有历史？"),
            isPresented: $store.isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(clearHistoryButtonTitle, role: .destructive) {
                clearHistory()
            }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(L10n.string("此操作无法撤销，但不会影响当前系统剪贴板。"))
        }
        .onAppear {
            windowCoordinator.registerMainWindowOpener { openWindow(id: "main") }
            store.startMonitoring()
            refreshVisibleItems(from: store.items)
            handleWindowPresented()
        }
        .onChange(of: searchText) { _ in
            refreshVisibleItems(from: store.items)
        }
        // `$items` publishes the new value before the property changes.
        .onReceive(store.$items) { items in
            refreshVisibleItems(from: items)
        }
        .onDeleteCommand(perform: deleteSelectedItem)
        .onReceive(NotificationCenter.default.publisher(for: .clipDeckMainWindowPresented)) { _ in
            handleWindowPresented()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
            notification in
            guard let window = notification.object as? NSWindow,
                  WindowCoordinator.isMainWindow(window) else {
                return
            }
            store.isClearConfirmationPresented = false
            windowCoordinator.forgetPreviousApplication()
        }
    }

    private var clearHistoryButtonTitle: String {
        if store.items.count == 1 {
            return L10n.string("清空 1 条历史")
        }
        return L10n.string("清空 %lld 条历史", Int64(store.items.count))
    }

    private var statusText: String {
        let recordingStatus = store.isMonitoring
            ? L10n.string("正在记录文字、图片与文件")
            : L10n.string("记录已暂停")
        if hotKeyManager.errorMessage != nil {
            return L10n.string("%@ · 全局快捷键不可用", recordingStatus)
        }
        guard let shortcut = hotKeyManager.shortcutDescription else {
            return L10n.string("%@ · 全局快捷键已关闭", recordingStatus)
        }
        return L10n.string("%@ · 全局唤起 %@", recordingStatus, shortcut)
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(L10n.string("剪贴板历史"))
                            .font(.title2.weight(.semibold))
                        Text(AppVersion.current.shortLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(AppVersion.current.displayText)
                    }

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.string("状态：%@", statusText))
                }

                Spacer()

                AppSettingsButton(
                    title: L10n.string("设置"),
                    systemImage: "gearshape"
                )
                .help(L10n.string("打开 ClipDeck 设置"))

                Button {
                    store.isMonitoring.toggle()
                } label: {
                    Label(
                        store.isMonitoring
                            ? L10n.string("暂停记录")
                            : L10n.string("开始记录"),
                        systemImage: store.isMonitoring ? "pause.fill" : "play.fill"
                    )
                }
                .help(
                    store.isMonitoring
                        ? L10n.string("暂停记录新的剪贴板内容")
                        : L10n.string("开始记录新的剪贴板内容")
                )

                Button {
                    store.isClearConfirmationPresented = true
                } label: {
                    Label(L10n.string("清空历史"), systemImage: "trash")
                }
                .disabled(store.items.isEmpty)
                .help(L10n.string("清空所有历史"))
            }

            HStack(spacing: 8) {
                searchField

                Spacer()

                historyNavigationButtons
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Button {
                focusedArea = .search
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help(L10n.string("搜索历史（⌘F）"))
            .accessibilityLabel(L10n.string("聚焦搜索历史"))

            TextField(L10n.string("搜索历史"), text: $searchText)
                .textFieldStyle(.plain)
                .focused($focusedArea, equals: .search)
                .help(L10n.string("多个关键词用空格分隔，需全部匹配"))
                .accessibilityLabel(L10n.string("搜索剪贴板历史"))
                .accessibilityHint(L10n.string("输入关键词筛选，按上下方向键选择结果"))

            if !searchText.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.string("清除搜索"))
                .accessibilityLabel(L10n.string("清除搜索"))
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 300, height: 26)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var historyNavigationButtons: some View {
        HStack(spacing: 4) {
            Button(action: selectPreviousItem) {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(!canSelectPreviousItem)
            .help(L10n.string("上一条（↑）"))
            .accessibilityLabel(L10n.string("选择上一条历史"))

            Button(action: selectNextItem) {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(!canSelectNextItem)
            .help(L10n.string("下一条（↓）"))
            .accessibilityLabel(L10n.string("选择下一条历史"))
        }
    }

    private var historyBrowser: some View {
        NavigationSplitView {
            historyList
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 320)
        } detail: {
            if let selectedItem {
                ClipboardDetailView(
                    item: selectedItem,
                    isCopied: store.lastCopiedItemID == selectedItem.id,
                    onCopy: { copy(selectedItem) },
                    onDelete: { delete(selectedItem) },
                    onCopyPlainText: { copy(selectedItem, plainTextOnly: true) }
                )
                .id(selectedItem.id)
            } else {
                ClipboardDetailPlaceholderView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedItemID) {
                ForEach(visibleItems) { item in
                    HistoryRow(
                        item: item,
                        isSelected: selectedItemID == item.id,
                        isCopied: store.lastCopiedItemID == item.id,
                        onSelect: { select(item) },
                        onCopy: { copy(item) },
                        onCopyPlainText: { copy(item, plainTextOnly: true) },
                        onDelete: {
                            select(item)
                            delete(item)
                        }
                    )
                    .tag(item.id)
                    .id(item.id)
                }
            }
            .listStyle(.sidebar)
            .focused($focusedArea, equals: .history)
            .accessibilityLabel(L10n.string("剪贴板历史列表"))
            .onChange(of: selectedItemID) { newSelection in
                guard let newSelection else {
                    return
                }
                proxy.scrollTo(newSelection)
            }
        }
    }

    private var selectedIndex: Int? {
        guard let selectedItemID else { return nil }
        return visibleItems.firstIndex { $0.id == selectedItemID }
    }

    private var canSelectPreviousItem: Bool {
        guard let index = selectedIndex else {
            return false
        }
        return index > 0
    }

    private var canSelectNextItem: Bool {
        let items = visibleItems
        guard let index = selectedIndex else {
            return !items.isEmpty
        }
        return index < items.count - 1
    }

    private func selectPreviousItem() {
        moveSelection(by: -1)
    }

    private func selectNextItem() {
        moveSelection(by: 1)
    }

    private func moveSelection(by offset: Int) {
        searchFocusRequestID = UUID()
        let items = visibleItems
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }

        guard let currentIndex = selectedIndex else {
            selectedItemID = items.first?.id
            focusedArea = .history
            return
        }
        let destination = min(max(0, currentIndex + offset), items.count - 1)
        selectedItemID = items[destination].id
        focusedArea = .history
    }

    private func select(_ item: ClipboardItem) {
        searchFocusRequestID = UUID()
        selectedItemID = item.id
        focusedArea = .history
    }

    private func refreshVisibleItems(from items: [ClipboardItem]) {
        cachedVisibleItems = ClipboardSearchQuery(searchText).filter(items)
        stabilizeSelection()
    }

    private func stabilizeSelection() {
        let items = visibleItems
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }

        if let selectedItemID, items.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = items.first?.id
    }

    private func copy(_ item: ClipboardItem, plainTextOnly: Bool = false) {
        selectedItemID = item.id
        guard store.copy(item, plainTextOnly: plainTextOnly) else {
            announce(L10n.string("复制失败"))
            return
        }
        announce(plainTextOnly ? L10n.string("文字已复制") : item.localizedCopiedAnnouncement)
        windowCoordinator.returnToPreviousApplicationIfNeeded()
    }

    private func deleteSelectedItem() {
        guard focusedArea == .history, let selectedItem else {
            return
        }
        delete(selectedItem)
    }

    private func delete(_ item: ClipboardItem) {
        guard store.index(of: item) != nil else {
            return
        }

        let items = visibleItems
        let visibleIndex = items.firstIndex(where: { $0.id == item.id })
        let nextSelection = visibleIndex.flatMap { index -> ClipboardItem.ID? in
            if index + 1 < items.endIndex {
                return items[index + 1].id
            }
            if index > items.startIndex {
                return items[index - 1].id
            }
            return nil
        }

        store.delete(item, undoManager: undoManager)
        selectedItemID = nextSelection
        announce(store.lastDeletionCanBeUndone
            ? L10n.string("已删除，可从编辑菜单撤销")
            : L10n.string("已删除"))

        DispatchQueue.main.async {
            focusedArea = nextSelection == nil ? .search : .history
        }
    }

    private func clearHistory() {
        store.clearHistory()
        selectedItemID = nil
        focusedArea = .search
        announce(L10n.string("剪贴板历史已清空"))
    }

    private func clearSearch() {
        searchText = ""
        refreshVisibleItems(from: store.items)
        focusedArea = .search
    }

    private func closeWindow() {
        windowCoordinator.returnToPreviousApplication(closeKeyWindow: true)
    }

    private func handleEscape() {
        if store.isClearConfirmationPresented {
            store.isClearConfirmationPresented = false
        } else {
            closeWindow()
        }
    }

    private func handleWindowPresented() {
        // A new window can report both onAppear and the presentation notification.
        // Handle that request once so the second callback cannot steal row focus.
        guard handledPresentationID != windowCoordinator.presentationID else { return }
        handledPresentationID = windowCoordinator.presentationID
        if let itemID = windowCoordinator.takeRequestedItemID(),
           let item = store.items.first(where: { $0.id == itemID }) {
            searchText = ""
            refreshVisibleItems(from: store.items)
            select(item)
        } else {
            scheduleSearchFocus()
        }
    }

    private func scheduleSearchFocus() {
        let requestID = UUID()
        searchFocusRequestID = requestID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard searchFocusRequestID == requestID,
                  WindowCoordinator.isMainWindow(NSApp.keyWindow) else {
                return
            }
            focusedArea = .search
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

/// One history row. Hover state lives here, so moving the pointer across the
/// list redraws a single row instead of the whole window.
private struct HistoryRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isCopied: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onCopyPlainText: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            ClipboardRowView(item: item, isCopied: isCopied)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Double-click copies; the simultaneous single tap still selects
                // immediately instead of waiting for the double-click timeout.
                .onTapGesture(count: 2, perform: onCopy)
                .simultaneousGesture(TapGesture().onEnded { onSelect() })
                .accessibilityAction(named: Text(L10n.string("复制")), onCopy)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .opacity(isHovered || isSelected ? 1 : 0.4)
            .help(L10n.string("删除此条历史（可撤销）"))
            .accessibilityLabel(L10n.string("删除：%@", item.preview))
            .accessibilityHint(L10n.string("删除后可从编辑菜单撤销"))
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(item.localizedCopyActionTitle, action: onCopy)

            if item.hasRichText {
                Button(L10n.string("复制为纯文本"), action: onCopyPlainText)
            }

            Divider()

            Button(L10n.string("删除"), role: .destructive, action: onDelete)
        }
    }
}
