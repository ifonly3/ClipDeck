import SwiftUI

struct ClipboardDetailView: View {
    let item: ClipboardItem
    let isCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

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
                item.image == nil ? "文字" : "图片",
                systemImage: item.image == nil ? "doc.text" : "photo"
            )
            .font(.headline)

            Text(item.timestampText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if isCopied {
                Label("已复制", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("状态：已复制")
            }

            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
            .help("删除此条历史（Delete，可撤销）")
            .accessibilityHint("删除后可从编辑菜单撤销")

            Button(action: onCopy) {
                Label(isCopied ? "再次复制" : "复制", systemImage: "doc.on.doc")
            }
            .keyboardShortcut(.defaultAction)
            .help("复制到系统剪贴板（Return）")
            .accessibilityHint("将内容复制到系统剪贴板")
        }
        .padding(14)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let text):
            ScrollView {
                Text(verbatim: text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
            .accessibilityLabel("文字内容")

        case .image(let image):
            VStack(spacing: 14) {
                Spacer(minLength: 16)

                Image(nsImage: image.thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 320)
                    .accessibilityLabel("图片预览，\(image.dimensionsText)")

                Text(image.dimensionsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var keyboardHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .accessibilityHidden(true)
            Text("单击选择 · ↑↓ 切换 · Return 复制 · Delete 删除 · Esc 关闭")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("操作：单击选择，上下方向键切换，回车复制，删除键删除，Escape 关闭窗口")
    }
}

struct ClipboardDetailPlaceholderView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("选择一条历史以预览")
                .font(.headline)

            Text("使用 ↑↓ 选择，按 Return 复制。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}
