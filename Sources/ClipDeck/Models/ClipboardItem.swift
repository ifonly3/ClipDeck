import AppKit
import Foundation

struct ClipboardImage {
    let data: Data
    let pasteboardType: NSPasteboard.PasteboardType
    let pixelWidth: Int
    let pixelHeight: Int
    let fingerprint: Data
    let thumbnail: NSImage

    init?(processed: ProcessedClipboardImage) {
        guard let thumbnail = NSImage(data: processed.thumbnailData) else {
            return nil
        }

        self.data = processed.data
        self.pasteboardType = NSPasteboard.PasteboardType(processed.typeIdentifier)
        self.pixelWidth = processed.pixelWidth
        self.pixelHeight = processed.pixelHeight
        self.fingerprint = processed.fingerprint
        self.thumbnail = thumbnail
    }

    var dimensionsText: String {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return "未知尺寸"
        }

        return "\(pixelWidth)×\(pixelHeight)"
    }
}

struct ClipboardItem: Identifiable {
    enum Content {
        case text(String)
        case image(ClipboardImage)
    }

    let id: UUID
    let content: Content
    let capturedAt: Date

    /// Kept for source compatibility with existing callers.
    var copiedAt: Date { capturedAt }

    /// Cached display/search values avoid rebuilding large strings on each SwiftUI update.
    let preview: String
    let menuTitle: String
    let searchableText: String
    let timestampText: String

    init(id: UUID = UUID(), text: String, copiedAt: Date = .now) {
        self.init(id: id, content: .text(text), copiedAt: copiedAt)
    }

    init(id: UUID = UUID(), image: ClipboardImage, copiedAt: Date = .now) {
        self.init(id: id, content: .image(image), copiedAt: copiedAt)
    }

    init(id: UUID = UUID(), content: Content, copiedAt: Date = .now) {
        self.id = id
        self.content = content
        self.capturedAt = copiedAt
        self.timestampText = copiedAt.formatted(date: .omitted, time: .shortened)

        let preview: String
        let searchableText: String
        switch content {
        case .text(let text):
            let normalized = text
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            preview = normalized.isEmpty ? "空白文本" : normalized.truncated(to: 140)
            searchableText = Self.normalizedSearchText(text)
        case .image(let image):
            preview = "图片 · \(image.dimensionsText)"
            searchableText = Self.normalizedSearchText(
                "图片 图像 image \(image.dimensionsText)"
            )
        }

        self.preview = preview
        self.menuTitle = preview.truncated(to: 30)
        self.searchableText = searchableText
    }

    var text: String? {
        guard case .text(let text) = content else {
            return nil
        }

        return text
    }

    var image: ClipboardImage? {
        guard case .image(let image) = content else {
            return nil
        }

        return image
    }

    func hasSameContent(as other: ClipboardItem) -> Bool {
        switch (content, other.content) {
        case (.text(let left), .text(let right)):
            return left == right
        case (.image(let left), .image(let right)):
            return left.data.count == right.data.count
                && left.fingerprint == right.fingerprint
                && left.data == right.data
        default:
            return false
        }
    }

    static func normalizedSearchText(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }
}
