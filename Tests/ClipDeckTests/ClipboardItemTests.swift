import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ClipDeck

@Test
func previewCollapsesWhitespaceAndKeepsTextReadable() {
    let item = ClipboardItem(text: "  First line\n\nSecond line  ")

    #expect(item.preview == "First line Second line")
}

@Test
func menuTitleNeverExceedsThirtyCharacters() {
    let item = ClipboardItem(text: String(repeating: "a", count: 80))

    #expect(item.menuTitle.count == 30)
    #expect(item.menuTitle.hasSuffix("…"))
}

@Test
func truncationKeepsTheRequestedLimit() {
    #expect("abcdef".truncated(to: 4) == "abc…")
    #expect("abcdef".truncated(to: 0).isEmpty)
}

@Test @MainActor
func imageClipboardContentCanBeCapturedSearchedAndCopiedBack() async throws {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 96,
        pixelsHigh: 54,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 96 * 4,
        bitsPerPixel: 32
    ))
    let tiffData = try #require(bitmap.representation(using: .tiff, properties: [:]))
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("ClipDeckTests.\(UUID().uuidString)")
    )
    let defaultsSuite = "ClipDeckTests.image.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    defaults.set(true, forKey: "monitoring")
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    pasteboard.clearContents()

    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults,
        monitoringDefaultsKey: "monitoring"
    )
    pasteboard.clearContents()
    #expect(pasteboard.setString("同一次复制附带的文字", forType: .string))
    #expect(pasteboard.setData(tiffData, forType: .tiff))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    let item = try #require(store.items.first)
    let image = try #require(item.image)
    #expect(image.pixelWidth == 96)
    #expect(image.pixelHeight == 54)
    #expect(image.pasteboardType == .tiff)
    #expect(item.preview == "图片 · 96×54")
    #expect(store.filteredItems(matching: "图片").count == 1)

    store.copy(item)

    #expect(pasteboard.data(forType: image.pasteboardType) == image.data)
    let copiedImage = try #require(NSImage(pasteboard: pasteboard))
    #expect(Int(copiedImage.size.width.rounded()) == 96)
    #expect(Int(copiedImage.size.height.rounded()) == 54)
    #expect(store.items.count == 1)
    #expect(store.items.first?.id == item.id)
}

@Test @MainActor
func jpegClipboardContentIsRecognizedAsAnImage() async throws {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 24,
        pixelsHigh: 16,
        bitsPerSample: 8,
        samplesPerPixel: 3,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 24 * 3,
        bitsPerPixel: 24
    ))
    let jpegData = try #require(bitmap.representation(
        using: .jpeg,
        properties: [.compressionFactor: 0.8]
    ))
    let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("ClipDeckTests.\(UUID().uuidString)")
    )
    let defaultsSuite = "ClipDeckTests.jpeg.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    defaults.set(true, forKey: "monitoring")
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    pasteboard.clearContents()
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults,
        monitoringDefaultsKey: "monitoring"
    )

    pasteboard.clearContents()
    #expect(pasteboard.setData(jpegData, forType: jpegType))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    let item = try #require(store.items.first)
    let image = try #require(item.image)
    #expect(image.pixelWidth == 24)
    #expect(image.pixelHeight == 16)
    #expect(image.pasteboardType == jpegType)

    store.copy(item)

    #expect(pasteboard.data(forType: jpegType) == jpegData)
    let copiedImage = try #require(NSImage(pasteboard: pasteboard))
    #expect(Int(copiedImage.size.width.rounded()) == 24)
    #expect(Int(copiedImage.size.height.rounded()) == 16)
}
