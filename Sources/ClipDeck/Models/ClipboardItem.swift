import AppKit
import Foundation
import UniformTypeIdentifiers

struct ClipboardImage {
    let data: Data
    let pasteboardType: NSPasteboard.PasteboardType
    let representations: [NSPasteboard.PasteboardType: Data]
    let pixelWidth: Int
    let pixelHeight: Int
    let fingerprint: Data
    let thumbnail: NSImage
    let preview: NSImage
    let renderingByteCount: Int
    let textRepresentation: String?

    init?(processed: ProcessedClipboardImage, textRepresentation: String? = nil) {
        guard let thumbnail = NSImage(data: processed.thumbnailData) else {
            return nil
        }

        self.data = processed.data
        self.pasteboardType = NSPasteboard.PasteboardType(processed.typeIdentifier)
        var representations = processed.additionalRepresentations.reduce(
            into: [NSPasteboard.PasteboardType: Data]()
        ) { result, representation in
            result[NSPasteboard.PasteboardType(representation.key)] = representation.value
        }
        representations[self.pasteboardType] = processed.data
        self.representations = representations
        self.pixelWidth = processed.pixelWidth
        self.pixelHeight = processed.pixelHeight
        self.fingerprint = processed.fingerprint
        self.thumbnail = thumbnail
        self.preview = processed.previewData.flatMap(NSImage.init(data:)) ?? thumbnail
        self.renderingByteCount = processed.thumbnailData.count
            + (processed.previewData?.count ?? 0)
        self.textRepresentation = textRepresentation
    }

    var dimensionsText: String {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return L10n.string("未知尺寸")
        }

        return "\(pixelWidth)×\(pixelHeight)"
    }

    var storageByteCount: Int {
        representations.values.reduce(renderingByteCount) { partialResult, data in
            partialResult + data.count
        }
    }
}

/// One original pasteboard item. Values are immutable snapshots, never lazy providers.
struct ClipboardRepresentationItem: Sendable, Equatable {
    let representations: [String: Data]

    var byteCount: Int { representations.values.reduce(0) { $0 + $1.count } }
}

struct ClipboardFileReference {
    let url: URL
    let displayName: String
    let isDirectory: Bool

    init(url: URL) {
        let standardizedURL = url.standardizedFileURL
        self.url = standardizedURL
        self.displayName = standardizedURL.lastPathComponent.isEmpty
            ? standardizedURL.path
            : standardizedURL.lastPathComponent
        // This is deliberately only a URL hint. Reading resource metadata or
        // requesting file icons here can block the main actor for network,
        // cloud, or disconnected-volume URLs while the clipboard is polled.
        self.isDirectory = standardizedURL.hasDirectoryPath
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    var systemImageName: String {
        isDirectory ? "folder" : "doc"
    }
}

struct ClipboardFileList {
    let references: [ClipboardFileReference]

    init?(urls: [URL]) {
        var seenURLs = Set<String>()
        let uniqueURLs = urls.compactMap { url -> URL? in
            guard url.isFileURL else {
                return nil
            }

            let standardizedURL = url.standardizedFileURL
            guard seenURLs.insert(standardizedURL.absoluteString).inserted else {
                return nil
            }
            return standardizedURL
        }
        guard !uniqueURLs.isEmpty else {
            return nil
        }

        self.references = uniqueURLs.map(ClipboardFileReference.init(url:))
    }

    var urls: [URL] {
        references.map(\.url)
    }

    fileprivate var comparisonKey: [String] {
        references.map { $0.url.absoluteString }.sorted()
    }
}

struct ClipboardItem: Identifiable {
    enum Content {
        case text(String)
        case image(ClipboardImage)
        case files(ClipboardFileList)
    }

    let id: UUID
    let content: Content
    let parts: [Content]
    let originalItems: [ClipboardRepresentationItem]
    let captureNote: String?
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

    init(id: UUID = UUID(), files: ClipboardFileList, copiedAt: Date = .now) {
        self.init(id: id, content: .files(files), copiedAt: copiedAt)
    }

    init(id: UUID = UUID(), content: Content, copiedAt: Date = .now) {
        self.init(id: id, parts: [content], originalItems: [], copiedAt: copiedAt)
    }

    init(
        id: UUID = UUID(),
        parts: [Content],
        originalItems: [ClipboardRepresentationItem] = [],
        captureNote: String? = nil,
        copiedAt: Date = .now
    ) {
        precondition(!parts.isEmpty)
        let content = parts[0]
        self.id = id
        self.content = content
        self.parts = parts
        self.originalItems = originalItems
        self.captureNote = captureNote
        self.capturedAt = copiedAt
        self.timestampText = copiedAt.formatted(date: .omitted, time: .shortened)

        let preview: String
        let searchableText: String
        switch content {
        case .text(let text):
            let normalized = text
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            preview = normalized.isEmpty
                ? L10n.string("空白文本")
                : normalized.truncated(to: 140)
            searchableText = Self.normalizedSearchText(text)
        case .image(let image):
            let isPDF = image.pasteboardType.rawValue == UTType.pdf.identifier
            preview = isPDF ? "PDF · " + image.dimensionsText : L10n.string("图片 · %@", image.dimensionsText)
            searchableText = Self.normalizedSearchText(
                "图片 图像 image \(isPDF ? "PDF " : "")\(image.dimensionsText) \(image.textRepresentation ?? "")"
            )
        case .files(let files):
            if files.references.count == 1, let file = files.references.first {
                preview = file.isDirectory
                    ? L10n.string("文件夹 · %@", file.displayName)
                    : L10n.string("文件 · %@", file.displayName)
            } else {
                preview = L10n.string("%@ 等 %lld 个文件", files.references[0].displayName, Int64(files.references.count))
            }
            searchableText = Self.normalizedSearchText(
                files.references
                    .flatMap { [$0.displayName, $0.url.path] }
                    .joined(separator: " ")
                    + " 文件 文件夹 file folder"
            )
        }

        let groupedPreview = parts.count > 1
            ? L10n.string("组合内容 · %lld 项", Int64(parts.count)) + " · " + preview
            : preview
        self.preview = groupedPreview
        self.menuTitle = groupedPreview.truncated(to: 30)
        self.searchableText = searchableText + parts.dropFirst().map {
            ClipboardItem(content: $0, copiedAt: copiedAt).searchableText
        }.joined(separator: " ")
    }

    var isMultiPart: Bool { parts.count > 1 }

    var hasRichText: Bool {
        originalItems.contains { item in
            item.representations.keys.contains {
                $0 == NSPasteboard.PasteboardType.rtf.rawValue
                    || $0 == NSPasteboard.PasteboardType.rtfd.rawValue
                    || $0 == NSPasteboard.PasteboardType.html.rawValue
            }
        }
    }

    var plainText: String? {
        let values = parts.compactMap { part -> String? in
            switch part {
            case .text(let value): return value
            case .image(let image): return image.textRepresentation
            case .files: return nil
            }
        }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }

    /// Replay snapshots share image Data buffers with the display parts. Count
    /// those encodings once, plus separately owned text and preview buffers.
    var storageByteCount: Int {
        let hasReplaySnapshot = !originalItems.isEmpty
        return originalItems.reduce(0) { $0 + $1.byteCount } + parts.reduce(0) { count, part in
            switch part {
            case .text(let text): return count + text.utf8.count
            case .image(let image):
                return count + (hasReplaySnapshot ? image.renderingByteCount : image.storageByteCount)
            case .files(let files):
                return count + files.urls.reduce(0) { $0 + $1.absoluteString.utf8.count }
            }
        }
    }

    var mediaStorageByteCount: Int {
        storageByteCount
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

    var files: ClipboardFileList? {
        guard case .files(let files) = content else {
            return nil
        }

        return files
    }

    var localizedContentType: String {
        if isMultiPart { return L10n.string("组合内容") }
        if image?.pasteboardType.rawValue == UTType.pdf.identifier { return "PDF" }
        switch content {
        case .text:
            return L10n.string("文字")
        case .image:
            return L10n.string("图片")
        case .files:
            return L10n.string("文件")
        }
    }

    var systemImageName: String {
        if isMultiPart { return "square.stack.3d.up" }
        if image?.pasteboardType.rawValue == UTType.pdf.identifier { return "doc.richtext" }
        switch content {
        case .text:
            return "doc.text"
        case .image:
            return "photo"
        case .files:
            return "doc.on.doc"
        }
    }

    var localizedCopyActionTitle: String {
        if isMultiPart || hasRichText || image?.pasteboardType.rawValue == UTType.pdf.identifier {
            return L10n.string("复制完整内容到剪贴板")
        }
        switch content {
        case .text:
            return L10n.string("复制文字到剪贴板")
        case .image:
            return L10n.string("复制图片到剪贴板")
        case .files:
            return L10n.string("复制文件到剪贴板")
        }
    }

    var localizedCopiedAnnouncement: String {
        if isMultiPart || hasRichText || image?.pasteboardType.rawValue == UTType.pdf.identifier {
            return L10n.string("完整内容已复制")
        }
        switch content {
        case .text:
            return L10n.string("文字已复制")
        case .image:
            return L10n.string("图片已复制")
        case .files:
            return L10n.string("文件已复制")
        }
    }

    func hasSameContent(as other: ClipboardItem) -> Bool {
        guard parts.count == other.parts.count else { return false }
        // Preserve two equal-looking text snippets with different formatting.
        let urlType = NSPasteboard.PasteboardType.URL.rawValue
        let containsTypedURL = originalItems.contains { $0.representations[urlType] != nil }
        let otherContainsTypedURL = other.originalItems.contains { $0.representations[urlType] != nil }
        if hasRichText || other.hasRichText || containsTypedURL || otherContainsTypedURL {
            guard originalItems == other.originalItems else { return false }
        }
        return zip(parts, other.parts).allSatisfy { Self.samePart($0.0, $0.1) }
    }

    private static func samePart(_ leftPart: Content, _ rightPart: Content) -> Bool {
        switch (leftPart, rightPart) {
        case (.text(let left), .text(let right)):
            return left == right
        case (.image(let left), .image(let right)):
            return left.data.count == right.data.count
                && left.fingerprint == right.fingerprint
                && left.data == right.data
                && left.textRepresentation == right.textRepresentation
        case (.files(let left), .files(let right)):
            return left.comparisonKey == right.comparisonKey
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
