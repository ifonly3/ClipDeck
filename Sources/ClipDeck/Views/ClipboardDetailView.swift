import SwiftUI

struct ClipboardDetailView: View {
    let item: ClipboardItem
    let isCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    var onCopyPlainText: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if let captureNote = item.captureNote {
                Label(captureNote, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
            }

            if item.hasRichText {
                HStack {
                    Text(L10n.string("已保留格式；下方显示文字预览。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let onCopyPlainText {
                        Button(L10n.string("复制为纯文本"), action: onCopyPlainText)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
            }

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            keyboardHint
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(
                item.localizedContentType,
                systemImage: item.systemImageName
            )
            .font(.headline)

            Text(item.timestampText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if isCopied {
                Label(L10n.string("已复制"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(L10n.string("状态：已复制"))
            }

            Button(role: .destructive, action: onDelete) {
                Label(L10n.string("删除"), systemImage: "trash")
            }
            .help(L10n.string("删除此条历史（Delete，可撤销）"))
            .accessibilityHint(L10n.string("删除后可从编辑菜单撤销"))

            Button(action: onCopy) {
                Label(
                    isCopied ? L10n.string("再次复制") : L10n.string("复制"),
                    systemImage: "doc.on.doc"
                )
            }
            .keyboardShortcut(.defaultAction)
            .help(L10n.string("复制到系统剪贴板（Return）"))
            .accessibilityHint(L10n.string("将内容复制到系统剪贴板"))
        }
        .padding(14)
    }

    @ViewBuilder
    private var preview: some View {
        if item.isMultiPart {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text(L10n.string("一次复制 · %lld 项", Int64(item.parts.count)))
                        .font(.headline)
                    ForEach(Array(item.parts.enumerated()), id: \.offset) { index, part in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.string("第 %lld 项", Int64(index + 1)))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ClipboardPartPreview(content: part)
                        }
                        if index < item.parts.count - 1 { Divider() }
                    }
                }
                .padding(18)
            }
        } else {
            ScrollView {
                ClipboardPartPreview(content: item.content)
                    .padding(18)
            }
        }
    }

    private var keyboardHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .accessibilityHidden(true)
            Text(
                L10n.string("单击选择 · ↑↓ 切换 · Return 复制 · Delete 删除 · Esc 关闭")
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.string(
                "操作：单击选择，上下方向键切换，回车复制，删除键删除，Escape 关闭窗口"
            )
        )
    }
}

struct ClipboardDetailPlaceholderView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(L10n.string("选择一条历史以预览"))
                .font(.headline)

            Text(L10n.string("使用 ↑↓ 选择，按 Return 复制。"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}
