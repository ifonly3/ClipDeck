import SwiftUI

struct ClipboardRowView: View {
    let item: ClipboardItem
    let isCopied: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingPreview

            VStack(alignment: .leading, spacing: 3) {
                Text(item.preview)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(item.timestampText)

                    if isCopied {
                        Label(L10n.string("已复制"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(L10n.string("选择后按回车，或使用“复制”操作"))
    }

    private var accessibilityLabel: String {
        let contentType = item.image == nil ? L10n.string("文字") : L10n.string("图片")
        let copyStatus = isCopied ? L10n.string("，已复制") : ""
        return L10n.string(
            "历史项目：%@，%@，%@%@",
            contentType,
            item.preview,
            item.timestampText,
            copyStatus
        )
    }

    @ViewBuilder
    private var leadingPreview: some View {
        if let image = item.image {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)

                Image(nsImage: image.thumbnail)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            }
            .frame(width: 54, height: 40)
            .accessibilityHidden(true)
        } else {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
        }
    }
}
