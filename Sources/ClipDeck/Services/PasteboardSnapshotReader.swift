import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PasteboardItemSnapshot: Sendable {
    let index: Int
    let types: [String]
    let representations: [String: Data]
    let unreadableTypes: [String]
    let oversizedTypes: [String]
    let imageSignature: Data
    let textRepresentation: String?

    var hasFiles: Bool { types.contains(where: PasteboardSnapshotReader.isFileType) }
    var byteCount: Int { representations.values.reduce(0) { $0 + $1.count } }
}

struct PasteboardSnapshot: Sendable {
    let changeCount: Int
    let items: [PasteboardItemSnapshot]
    let byteLimit: Int
    let imageByteLimit: Int
    let tooManyItems: Bool
    var byteCount: Int { items.reduce(0) { $0 + $1.byteCount } }
}

enum PasteboardSnapshotOutcome: Sendable {
    case success(PasteboardSnapshot)
    case changed
    case unavailable
    /// The privacy policy matched before any clipboard data was read.
    case skipped(CaptureSkipReason)
}

/// NSPasteboard caches and native text controls share AppKit state. Keep every
/// AppKit access on MainActor; only immutable snapshots reach ImageProcessor.
/// A slow source application's lazy provider can still delay this boundary.
final class PasteboardSnapshotReader: Sendable {
    struct Limits: Sendable {
        let maximumBytes: Int
        let maximumItems: Int
        let maximumImageCandidates: Int
        var maximumImageBytes: Int? = nil
        var maximumRichRepresentationBytes = 8 * 1024 * 1024
        /// Text longer than this is rejected anyway; derive at most one byte more.
        var maximumTextBytes: Int? = nil
        var privacy = CapturePrivacyRules.disabled
    }

    static let legacyFiles = "NSFilenamesPboardType"
    static let plainText = NSPasteboard.PasteboardType.string.rawValue
    static let richTypes = [
        NSPasteboard.PasteboardType.rtf.rawValue,
        NSPasteboard.PasteboardType.rtfd.rawValue,
        NSPasteboard.PasteboardType.html.rawValue
    ]

    func read(name: String, changeCount: Int, limits: Limits) async -> PasteboardSnapshotOutcome {
        await MainActor.run {
            guard !Task.isCancelled else { return .changed }
            return autoreleasepool {
                Self.readSynchronously(
                    pasteboard: NSPasteboard(name: .init(name)),
                    changeCount: changeCount,
                    limits: limits
                )
            }
        }
    }

    @MainActor
    static func readSynchronously(
        pasteboard: NSPasteboard,
        changeCount: Int,
        limits: Limits
    ) -> PasteboardSnapshotOutcome {
        guard pasteboard.changeCount == changeCount else { return .changed }
        guard let globalTypes = pasteboard.types else { return .unavailable }
        // Decide on privacy from type names alone, before any data is read.
        let typeNames = globalTypes.map(\.rawValue)
        let declaredSource = !limits.privacy.ignoredBundleIdentifiers.isEmpty
            && typeNames.contains(CapturePrivacyRules.sourceType)
            ? pasteboard.string(forType: .init(CapturePrivacyRules.sourceType))
            : nil
        if let reason = limits.privacy.skipReason(types: typeNames, declaredSource: declaredSource) {
            return .skipped(reason)
        }
        let sourceItems = pasteboard.pasteboardItems ?? []
        guard sourceItems.count <= limits.maximumItems else {
            return .success(.init(changeCount: changeCount, items: [], byteLimit: limits.maximumBytes,
                imageByteLimit: limits.maximumImageBytes ?? limits.maximumBytes, tooManyItems: true))
        }
        let sources: [NSPasteboardItem?] = sourceItems.isEmpty
            ? (globalTypes.isEmpty ? [] : [nil]) : sourceItems.map(Optional.some)
        var snapshots: [PasteboardItemSnapshot] = []
        var remainingBytes = limits.maximumBytes
        var remainingImageBytes = limits.maximumImageBytes ?? limits.maximumBytes

        for (index, source) in sources.enumerated() {
            guard pasteboard.changeCount == changeCount else { return .changed }
            let types = (source?.types ?? globalTypes).map(\.rawValue)
            let hasFiles = types.contains(where: isFileType)
            var selectedTypes: [String]
            if hasFiles {
                selectedTypes = types.filter(isFileType)
            } else {
                selectedTypes = imageTypes(types, maximumCandidates: limits.maximumImageCandidates)
                selectedTypes += ([plainText, NSPasteboard.PasteboardType.URL.rawValue] + richTypes)
                    .filter { types.contains($0) }
            }
            var representations: [String: Data] = [:]
            var unreadable: [String] = []
            var oversized: [String] = []
            var hasUsablePrimaryImage = false

            for type in selectedTypes {
                guard pasteboard.changeCount == changeCount else { return .changed }
                if hasUsablePrimaryImage && isImageType(type) { continue }
                if isImageType(type) && remainingImageBytes == 0 {
                    oversized.append(type)
                    continue
                }
                let pasteboardType = NSPasteboard.PasteboardType(type)
                let data = source?.data(forType: pasteboardType)
                    ?? (source == nil ? pasteboard.data(forType: pasteboardType) : nil)
                guard let data else { unreadable.append(type); continue }
                let typeLimit: Int
                if isImageType(type) { typeLimit = min(remainingBytes, remainingImageBytes) }
                else if richTypes.contains(type) { typeLimit = min(remainingBytes, limits.maximumRichRepresentationBytes) }
                else { typeLimit = remainingBytes }
                guard data.count <= typeLimit else { oversized.append(type); continue }
                representations[type] = data
                remainingBytes -= data.count
                if isImageType(type) { remainingImageBytes -= data.count }
                if isImageType(type), imageCanStandAlone(data) {
                    hasUsablePrimaryImage = true
                }
            }
            var imageHasher = SHA256()
            for type in selectedTypes where isImageType(type) {
                guard let data = representations[type] else { continue }
                imageHasher.update(data: Data(type.utf8))
                imageHasher.update(data: data)
            }
            snapshots.append(.init(
                index: index,
                types: types,
                representations: representations,
                unreadableTypes: unreadable,
                oversizedTypes: oversized,
                imageSignature: Data(imageHasher.finalize()),
                textRepresentation: text(from: representations, maximumBytes: limits.maximumTextBytes)
            ))
        }
        guard pasteboard.changeCount == changeCount else { return .changed }
        return .success(.init(
            changeCount: changeCount, items: snapshots,
            byteLimit: limits.maximumBytes,
            imageByteLimit: limits.maximumImageBytes ?? limits.maximumBytes, tooManyItems: false
        ))
    }

    static func isFileType(_ type: String) -> Bool {
        type == NSPasteboard.PasteboardType.fileURL.rawValue || type == legacyFiles
            || UTType(type)?.conforms(to: .fileURL) == true
    }

    static func isImageType(_ type: String) -> Bool {
        type == UTType.pdf.identifier || UTType(type)?.conforms(to: .image) == true
    }

    static func imageTypes(_ types: [String], maximumCandidates: Int) -> [String] {
        let preferred = types.enumerated().filter { isImageType($0.element) }.sorted {
            let left = imagePriority($0.element), right = imagePriority($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        var selected = Array(preferred.filter { !isTIFF($0) }.prefix(maximumCandidates))
        if let tiff = preferred.first(where: isTIFF) { selected.append(tiff) }
        return selected
    }

    private static func isTIFF(_ type: String) -> Bool {
        UTType(type)?.conforms(to: .tiff) == true
    }

    private static func imagePriority(_ type: String) -> Int {
        if type == UTType.pdf.identifier { return 0 }
        if type == UTType.png.identifier { return 1 }
        if isTIFF(type) { return 4 }
        guard let value = UTType(type) else { return 3 }
        return value.conforms(to: .jpeg) || value.conforms(to: .heic) || value.conforms(to: .gif) ? 2 : 3
    }

    private static func imageCanStandAlone(_ data: Data) -> Bool {
        guard data.count <= ClipboardImageSafetyLimits.maximumFinalBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .png) || type.conforms(to: .tiff),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= ClipboardImageSafetyLimits.maximumDimension,
              height <= ClipboardImageSafetyLimits.maximumDimension,
              Int64(width) * Int64(height) <= ClipboardImageSafetyLimits.maximumPixelCount else { return false }
        return true
    }

    /// - Parameter maximumBytes: Text beyond this size is rejected by the store.
    ///   Oversized sources return a string just over the limit, so callers can
    ///   report the size without decoding or deriving megabytes of text.
    static func text(from representations: [String: Data], maximumBytes: Int? = nil) -> String? {
        if let data = representations[plainText] {
            if let maximumBytes, data.count > maximumBytes {
                return String(decoding: data.prefix(maximumBytes + 1), as: UTF8.self)
            }
            if let text = String(data: data, encoding: .utf8) { return text }
        }
        if let data = representations[NSPasteboard.PasteboardType.URL.rawValue],
           let url = String(data: data, encoding: .utf8) { return url }
        for (type, documentType) in [
            (NSPasteboard.PasteboardType.rtf.rawValue, NSAttributedString.DocumentType.rtf),
            (NSPasteboard.PasteboardType.rtfd.rawValue, NSAttributedString.DocumentType.rtfd)
        ] {
            if let data = representations[type],
               let attributed = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil) {
                return attributed.string
            }
        }
        if let data = representations[NSPasteboard.PasteboardType.html.rawValue],
           let html = String(data: data, encoding: .utf8) {
            return HTMLTextExtractor.plainText(fromHTML: html, maximumOutputBytes: maximumBytes)
        }
        return nil
    }
}
