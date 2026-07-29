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
    @State private var selectedItemID: ClipboardItem.ID?
    @State private var hoveredItemID: ClipboardItem.ID?
    @FocusState private var focusedArea: FocusArea?

    private var filteredItems: [ClipboardItem] {
        store.filteredItems(matching: searchText)
    }

    private var filteredItemIDs: [ClipboardItem.ID] {
        filteredItems.map(\.id)
    }

    private var selectedItem: ClipboardItem? {
        guard let selectedItemID else {
            return nil
        }
        return filteredItems.first { $0.id == selectedItemID }
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
                onRetryHotKey: registerHotKey
            )

            Divider()

            if filteredItems.isEmpty {
                EmptyStateView(
                    isSearching: !normalizedSearchText.isEmpty,
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
            WindowKeyboardBridge {
                if store.isClearConfirmationPresented {
                    store.isClearConfirmationPresented = false
                } else {
                    closeWindow()
                }
            }
            .frame(width: 0, height: 0)
        }
        .confirmationDialog(
            "清空所有历史？",
            isPresented: $store.isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("清空 \(store.items.count) 条历史", role: .destructive) {
                clearHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作无法撤销，但不会影响当前系统剪贴板。")
        }
        .onAppear {
            store.startMonitoring()
            registerHotKey()
            stabilizeSelection()
            scheduleSearchFocus()
        }
        .onChange(of: filteredItemIDs) { _ in
            stabilizeSelection()
        }
        .onDeleteCommand(perform: deleteSelectedItem)
        .onExitCommand(perform: closeWindow)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "ClipDeck" else {
                return
            }
            scheduleSearchFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
            notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "ClipDeck" else {
                return
            }
            windowCoordinator.forgetPreviousApplication()
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusText: String {
        let recordingStatus = store.isMonitoring ? "正在记录文字与图片" : "记录已暂停"
        if hotKeyManager.errorMessage == nil {
            return "\(recordingStatus) · 全局唤起 \(GlobalHotKeyManager.shortcutDescription)"
        }
        return "\(recordingStatus) · 全局快捷键不可用"
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("剪贴板历史")
                        .font(.title2.weight(.semibold))

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("状态：\(statusText)")
                }

                Spacer()

                Button {
                    store.isMonitoring.toggle()
                } label: {
                    Label(
                        store.isMonitoring ? "暂停记录" : "开始记录",
                        systemImage: store.isMonitoring ? "pause.fill" : "play.fill"
                    )
                }
                .help(store.isMonitoring ? "暂停记录新的剪贴板内容" : "开始记录新的剪贴板内容")

                Button {
                    store.isClearConfirmationPresented = true
                } label: {
                    Label("清空历史", systemImage: "trash")
                }
                .disabled(store.items.isEmpty)
                .help("清空所有历史")
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
            .help("搜索历史（⌘F）")
            .accessibilityLabel("聚焦搜索历史")

            TextField("搜索历史", text: $searchText)
                .textFieldStyle(.plain)
                .focused($focusedArea, equals: .search)
                .accessibilityLabel("搜索剪贴板历史")
                .accessibilityHint("输入关键词筛选，按上下方向键选择结果")

            if !searchText.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
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
            .help("上一条（↑）")
            .accessibilityLabel("选择上一条历史")

            Button(action: selectNextItem) {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(!canSelectNextItem)
            .help("下一条（↓）")
            .accessibilityLabel("选择下一条历史")
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
                    onDelete: { delete(selectedItem) }
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
                ForEach(filteredItems) { item in
                    HStack(spacing: 6) {
                        ClipboardRowView(
                            item: item,
                            isCopied: store.lastCopiedItemID == item.id
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            copy(item)
                        }
                        .accessibilityAction(named: "复制") {
                            copy(item)
                        }

                        Button(role: .destructive) {
                            selectedItemID = item.id
                            delete(item)
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .opacity(hoveredItemID == item.id || selectedItemID == item.id ? 1 : 0.4)
                        .help("删除此条历史（可撤销）")
                        .accessibilityLabel("删除：\(item.preview)")
                        .accessibilityHint("删除后可从编辑菜单撤销")
                    }
                    .tag(item.id)
                    .id(item.id)
                    .onHover { isHovering in
                        hoveredItemID = isHovering ? item.id : nil
                    }
                    .contextMenu {
                        Button(item.image == nil ? "复制文字到剪贴板" : "复制图片到剪贴板") {
                            copy(item)
                        }

                        Divider()

                        Button("删除", role: .destructive) {
                            selectedItemID = item.id
                            delete(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .focused($focusedArea, equals: .history)
            .accessibilityLabel("剪贴板历史列表")
            .onChange(of: selectedItemID) { newSelection in
                guard let newSelection else {
                    return
                }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newSelection, anchor: .center)
                }
            }
        }
    }

    private var canSelectPreviousItem: Bool {
        guard let selectedItemID,
              let index = filteredItems.firstIndex(where: { $0.id == selectedItemID }) else {
            return false
        }
        return index > filteredItems.startIndex
    }

    private var canSelectNextItem: Bool {
        guard let selectedItemID,
              let index = filteredItems.firstIndex(where: { $0.id == selectedItemID }) else {
            return !filteredItems.isEmpty
        }
        return index < filteredItems.index(before: filteredItems.endIndex)
    }

    private func selectPreviousItem() {
        moveSelection(by: -1)
    }

    private func selectNextItem() {
        moveSelection(by: 1)
    }

    private func moveSelection(by offset: Int) {
        guard !filteredItems.isEmpty else {
            selectedItemID = nil
            return
        }

        guard let currentIndex = selectedItemID.flatMap({ selectedID in
            filteredItems.firstIndex { $0.id == selectedID }
        }) else {
            selectedItemID = filteredItems.first?.id
            focusedArea = .history
            return
        }
        let destination = min(
            max(filteredItems.startIndex, currentIndex + offset),
            filteredItems.index(before: filteredItems.endIndex)
        )
        selectedItemID = filteredItems[destination].id
        focusedArea = .history
    }

    private func stabilizeSelection() {
        guard !filteredItems.isEmpty else {
            selectedItemID = nil
            return
        }

        if let selectedItemID, filteredItems.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = filteredItems.first?.id
    }

    private func copy(_ item: ClipboardItem) {
        selectedItemID = item.id
        guard store.copy(item) else {
            announce("复制失败")
            return
        }
        announce(item.image == nil ? "文字已复制" : "图片已复制")
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

        let visibleItems = filteredItems
        let visibleIndex = visibleItems.firstIndex(where: { $0.id == item.id })
        let nextSelection = visibleIndex.flatMap { index -> ClipboardItem.ID? in
            if index + 1 < visibleItems.endIndex {
                return visibleItems[index + 1].id
            }
            if index > visibleItems.startIndex {
                return visibleItems[index - 1].id
            }
            return nil
        }

        store.delete(item, undoManager: undoManager)
        selectedItemID = nextSelection
        announce("已删除，可从编辑菜单撤销")
    }

    private func clearHistory() {
        store.clearHistory()
        selectedItemID = nil
        announce("剪贴板历史已清空")
    }

    private func clearSearch() {
        searchText = ""
        stabilizeSelection()
        focusedArea = .search
    }

    private func registerHotKey() {
        hotKeyManager.register {
            windowCoordinator.presentMainWindow {
                openWindow(id: "main")
            }
        }
    }

    private func closeWindow() {
        windowCoordinator.returnToPreviousApplication(closeKeyWindow: true)
    }

    private func scheduleSearchFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard NSApp.keyWindow?.title == "ClipDeck" else {
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
