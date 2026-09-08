import SwiftUI

/// Displays a saved part without deciding which clipboard formats to preserve.
struct ClipboardPartPreview: View {
    let content: ClipboardItem.Content

    @ViewBuilder
    var body: some View {
        switch content {
        case .text(let text):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L10n.string("空白文本 · %lld 个字符", Int64(text.count)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(verbatim: text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .accessibilityLabel(L10n.string("文字内容"))
            }
        case .image(let image):
            VStack(spacing: 12) {
                Image(nsImage: image.preview)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: 480, maxHeight: 360)
                    .accessibilityLabel(L10n.string("图片预览，%@", image.dimensionsText))
                Text(image.dimensionsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        case .files(let files):
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(files.references, id: \.url) { file in
                    HStack(spacing: 12) {
                        Image(systemName: file.systemImageName)
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.displayName)
                                .textSelection(.enabled)
                            Text(file.url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityLabel(L10n.string("文件列表，共 %lld 项", Int64(files.references.count)))
        }
    }
}
