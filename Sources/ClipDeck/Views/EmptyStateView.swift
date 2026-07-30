import SwiftUI

struct EmptyStateView: View {
    let isSearching: Bool
    let isMonitoring: Bool
    let onClearSearch: () -> Void
    let onStartMonitoring: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isSearching ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isSearching {
                Button(L10n.string("清除搜索"), action: onClearSearch)
                    .accessibilityHint(L10n.string("清除关键词并显示全部剪贴板历史"))
            } else if !isMonitoring {
                Button(L10n.string("开始记录"), action: onStartMonitoring)
                    .accessibilityHint(L10n.string("从现在开始记录新复制的文字与图片"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if isSearching {
            return L10n.string("没有匹配的历史")
        }
        return isMonitoring ? L10n.string("还没有记录") : L10n.string("记录已暂停")
    }

    private var message: String {
        if isSearching {
            return L10n.string("试试其他关键词。")
        }
        if isMonitoring {
            return L10n.string("复制文字或图片后，它会出现在这里。")
        }
        return L10n.string("开启记录后，ClipDeck 会从那一刻起保存你复制的文字与图片。")
    }
}
