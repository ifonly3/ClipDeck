import AppKit
import Foundation

/// Marks ClipDeck's own writes so a restore can verify it won the clipboard race.
let restoreTokenPasteboardType = NSPasteboard.PasteboardType("com.qiaoni.clipdeck.restore-token")

/// Builds the exact pasteboard payload for restoring one history item.
@MainActor
enum ClipboardRestorePayload {
    static func make(
        for item: ClipboardItem,
        restoreToken: String,
        plainTextOnly: Bool = false
    ) -> [NSPasteboardWriting]? {
        if plainTextOnly {
            guard let text = item.plainText else { return nil }
            return make(for: ClipboardItem(text: text), restoreToken: restoreToken)
        }
        if !item.originalItems.isEmpty {
            var result: [NSPasteboardWriting] = []
            for (index, original) in item.originalItems.enumerated() {
                let value = NSPasteboardItem()
                for entry in entriesRebuildingDroppedRasters(original) {
                    guard value.setData(entry.data, forType: .init(entry.type)) else { return nil }
                }
                if index == 0 {
                    guard value.setString(restoreToken, forType: restoreTokenPasteboardType) else { return nil }
                }
                result.append(value)
            }
            return result
        }
        if item.parts.count > 1 {
            var result: [NSPasteboardWriting] = []
            for part in item.parts {
                guard let values = make(for: ClipboardItem(content: part), restoreToken: restoreToken) else {
                    return nil
                }
                result += values
            }
            return result
        }
        switch item.content {
        case .text(let text):
            let pasteboardItem = NSPasteboardItem()
            guard pasteboardItem.setString(text, forType: .string),
                  pasteboardItem.setString(restoreToken, forType: restoreTokenPasteboardType) else {
                return nil
            }
            return [pasteboardItem]
        case .image(let image):
            return makePasteboardItem(for: image, restoreToken: restoreToken).map { [$0] }
        case .files(let files):
            var pasteboardItems: [NSPasteboardWriting] = []
            pasteboardItems.reserveCapacity(files.urls.count)
            for (index, url) in files.urls.enumerated() {
                let pasteboardItem = NSPasteboardItem()
                guard pasteboardItem.setString(url.absoluteString, forType: .fileURL) else {
                    return nil
                }
                if index == 0,
                   !pasteboardItem.setString(restoreToken, forType: restoreTokenPasteboardType) {
                    return nil
                }
                pasteboardItems.append(pasteboardItem)
            }
            return pasteboardItems
        }
    }

    /// The original entries in their recorded order. Compatibility rasters that
    /// history dropped to save memory are rebuilt and placed right after the
    /// image they were derived from, where they were originally written.
    static func entriesRebuildingDroppedRasters(
        _ original: ClipboardRepresentationItem
    ) -> [ClipboardRepresentationItem.Entry] {
        guard !original.droppedRebuildableTypes.isEmpty,
              let primaryIndex = original.entries.firstIndex(where: {
                  !$0.isRebuildable && PasteboardSnapshotReader.isImageType($0.type)
              }) else {
            return original.entries
        }
        let primary = original.entries[primaryIndex]
        let missingTypes = original.droppedRebuildableTypes.filter { !original.contains(type: $0) }
        let rebuilt = ImageProcessor.rebuildDerivedRepresentations(
            missingTypes,
            fromPrimary: primary.data,
            typeIdentifier: primary.type
        )
        let rebuiltEntries = ClipboardImage.orderedDerivedTypes(rebuilt.keys).compactMap { type in
            rebuilt[type].map { ClipboardRepresentationItem.Entry(type: type, data: $0, isRebuildable: true) }
        }
        var entries = original.entries
        entries.insert(contentsOf: rebuiltEntries, at: primaryIndex + 1)
        return entries
    }

    private static func makePasteboardItem(
        for image: ClipboardImage,
        restoreToken: String
    ) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        guard item.setData(image.data, forType: image.pasteboardType) else {
            return nil
        }
        let rebuilt = ImageProcessor.rebuildDerivedRepresentations(
            image.droppedDerivedTypes.map(\.rawValue),
            fromPrimary: image.data,
            typeIdentifier: image.pasteboardType.rawValue
        )
        let derived = image.derivedRepresentations.map { ($0.type, $0.data) }
            + ClipboardImage.orderedDerivedTypes(rebuilt.keys).compactMap { type in
                rebuilt[type].map { (NSPasteboard.PasteboardType(type), $0) }
            }
        for (type, data) in derived where type != image.pasteboardType {
            guard item.setData(data, forType: type) else {
                return nil
            }
        }
        if let textRepresentation = image.textRepresentation,
           !item.setString(textRepresentation, forType: .string) {
            return nil
        }
        guard item.setString(restoreToken, forType: restoreTokenPasteboardType) else {
            return nil
        }
        return item
    }
}

/// The lightweight part of the current clipboard kept to roll back a failed write.
struct PasteboardRecoverySnapshot {
    let items: [NSPasteboardItem]
    let isComplete: Bool
    let sourceChangeCount: Int

    private static let legacyFilenamesType = NSPasteboard.PasteboardType(PasteboardSnapshotReader.legacyFiles)

    @MainActor
    static func capture(from pasteboard: NSPasteboard, maximumBytes: Int) -> PasteboardRecoverySnapshot {
        let sourceChangeCount = pasteboard.changeCount
        guard let currentItems = pasteboard.pasteboardItems else {
            return PasteboardRecoverySnapshot(
                items: [],
                isComplete: pasteboard.types?.isEmpty ?? true,
                sourceChangeCount: sourceChangeCount
            )
        }

        var remainingBytes = maximumBytes
        var recoveryItems: [NSPasteboardItem] = []
        var isComplete = true
        recoveryItems.reserveCapacity(currentItems.count)

        for currentItem in currentItems {
            let recoveryItem = NSPasteboardItem()
            let recoverableTypes = currentItem.types
                .filter { type in
                    let isRecoverable = isRecoverable(type)
                    if !isRecoverable {
                        isComplete = false
                    }
                    return isRecoverable
                }
                .sorted { priority($0) < priority($1) }

            for type in recoverableTypes {
                guard let data = currentItem.data(forType: type),
                      data.count <= remainingBytes,
                      recoveryItem.setData(data, forType: type) else {
                    isComplete = false
                    continue
                }
                remainingBytes -= data.count
            }

            if recoveryItem.types.contains(where: isUserRecoverable) {
                recoveryItems.append(recoveryItem)
            }
            if remainingBytes == 0 {
                if recoveryItems.count < currentItems.count {
                    isComplete = false
                }
                break
            }
        }

        return PasteboardRecoverySnapshot(
            items: recoveryItems,
            isComplete: isComplete,
            sourceChangeCount: sourceChangeCount
        )
    }

    /// Reading an image representation just to prepare a rare failure rollback
    /// can synchronously materialize hundreds of megabytes from a lazy provider.
    /// Keep recovery lightweight; incomplete snapshots are reported honestly if
    /// the actual write ever fails.
    private static func isRecoverable(_ type: NSPasteboard.PasteboardType) -> Bool {
        type == .string || type == .fileURL || type == legacyFilenamesType || type == restoreTokenPasteboardType
    }

    private static func isUserRecoverable(_ type: NSPasteboard.PasteboardType) -> Bool {
        type == .string || type == .fileURL || type == legacyFilenamesType
    }

    private static func priority(_ type: NSPasteboard.PasteboardType) -> Int {
        if type == .string { return 0 }
        if type == .fileURL || type == legacyFilenamesType { return 1 }
        if type == restoreTokenPasteboardType { return 2 }
        return 3
    }
}
