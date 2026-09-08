import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ClipDeck

@Test @MainActor
func fileAndFolderURLsAreCapturedAsOneHistoryItem() throws {
    let fixture = try FileFixture()
    defer { fixture.remove() }
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([
        fixture.fileURL as NSURL,
        fixture.folderURL as NSURL
    ]))
    let clipboardChangeCount = pasteboard.changeCount

    store.pollPasteboard()

    let files = try #require(store.items.first?.files)
    #expect(files.urls == [fixture.fileURL, fixture.folderURL].map(\.standardizedFileURL))
    #expect(store.items.count == 1)
    #expect(pasteboard.changeCount == clipboardChangeCount)
}

@Test @MainActor
func fileURLsWinOverAuxiliaryImageRepresentations() async throws {
    let fixture = try FileFixture()
    defer { fixture.remove() }
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )
    let pasteboardItem = NSPasteboardItem()
    #expect(pasteboardItem.setString(
        fixture.fileURL.absoluteString,
        forType: .fileURL
    ))
    #expect(pasteboardItem.setData(
        try fileTestImageData(type: .png),
        forType: .png
    ))

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([pasteboardItem]))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    #expect(store.items.count == 1)
    #expect(store.items.first?.files?.urls == [fixture.fileURL.standardizedFileURL])
    #expect(store.items.first?.image == nil)
}

@Test @MainActor
func independentTextAndFileItemsAreBothCaptured() throws {
    let fixture = try FileFixture()
    defer { fixture.remove() }
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )
    let textItem = NSPasteboardItem()
    #expect(textItem.setString("Independent text", forType: .string))
    let objects: [NSPasteboardWriting] = [fixture.fileURL as NSURL, textItem]

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects(objects))
    store.pollPasteboard()

    #expect(store.items.count == 1)
    let grouped = try #require(store.items.first)
    #expect(grouped.parts.count == 2)
    #expect(grouped.isMultiPart)
    #expect(grouped.parts.contains { if case .text("Independent text") = $0 { return true }; return false })
    #expect(grouped.parts.contains {
        if case .files(let files) = $0 { return files.urls == [fixture.fileURL.standardizedFileURL] }
        return false
    })
}

@Test @MainActor
func blankTextItemDoesNotHideALaterValidImageItem() async throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )
    let blankItem = NSPasteboardItem()
    #expect(blankItem.setString("   ", forType: .string))
    let imageItem = NSPasteboardItem()
    #expect(imageItem.setData(try fileTestImageData(type: .png), forType: .png))

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([blankItem, imageItem]))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    #expect(store.items.count == 1)
    #expect(store.items.first?.parts.count == 2)
    #expect(store.items.first?.parts.contains { if case .image = $0 { return true }; return false } == true)
}

@Test @MainActor
func oneUnreadableItemKeepsTheWholePasteboardBatchRetryable() throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        configuration: .init(maximumReadRetryAttempts: 3)
    )
    let unreadableFileItem = NSPasteboardItem()
    let unavailableProvider = UnavailablePasteboardDataProvider()
    unreadableFileItem.setDataProvider(unavailableProvider, forTypes: [.fileURL])
    let textItem = NSPasteboardItem()
    #expect(textItem.setString("Still capture me", forType: .string))

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([unreadableFileItem, textItem]))

    store.pollPasteboard()
    #expect(store.items.contains { $0.text == "Still capture me" })
    #expect(
        store.captureWarning
            == L10n.string("检测到文件，但暂时无法读取；将自动重试。")
    )

    store.pollPasteboard()
    #expect(
        store.captureWarning
            == L10n.string("检测到文件，但暂时无法读取；将自动重试。")
    )

    store.pollPasteboard()
    #expect(
        store.captureWarning
            == L10n.string("文件连续多次读取失败，本次未记录。")
    )
    #expect(store.items.filter { $0.text == "Still capture me" }.count == 1)
    withExtendedLifetime(unavailableProvider) {}
}

@Test @MainActor
func unreadableFilePreventsAPartialMultiFileHistoryItem() throws {
    let fixture = try FileFixture()
    defer { fixture.remove() }
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )
    let unreadableFileItem = NSPasteboardItem()
    let unavailableProvider = UnavailablePasteboardDataProvider()
    unreadableFileItem.setDataProvider(unavailableProvider, forTypes: [.fileURL])

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([
        unreadableFileItem,
        fixture.fileURL as NSURL
    ]))
    store.pollPasteboard()

    #expect(store.items.allSatisfy { $0.files == nil })
    #expect(
        store.captureWarning
            == L10n.string("检测到文件，但暂时无法读取；将自动重试。")
    )
    withExtendedLifetime(unavailableProvider) {}
}

@Test @MainActor
func retryingABatchDoesNotQueueTheSameImageAgain() async throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let thumbnailData = try fileTestImageData(type: .png)
    let processor = CountingGatedImageProcessor(thumbnailData: thumbnailData)
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        imageProcessor: processor,
        configuration: .init(maximumReadRetryAttempts: 3)
    )
    let unreadableFileItem = NSPasteboardItem()
    let unavailableProvider = UnavailablePasteboardDataProvider()
    unreadableFileItem.setDataProvider(unavailableProvider, forTypes: [.fileURL])
    let imageItem = NSPasteboardItem()
    #expect(imageItem.setData(Data([7]), forType: .png))

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([unreadableFileItem, imageItem]))
    store.pollPasteboard()
    await processor.waitUntilStarted()

    store.pollPasteboard()
    await processor.release()
    await store.waitForPendingImageCapture()
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    let processorCallCount = await processor.numberOfCalls()
    #expect(processorCallCount == 1)
    #expect(store.items.filter { $0.image != nil }.count == 1)
    #expect(
        store.captureWarning
            == L10n.string("文件连续多次读取失败，本次未记录。")
    )
    withExtendedLifetime(unavailableProvider) {}
}

@Test @MainActor
func retryingTheSameBatchDoesNotHideItsPendingImageFailure() async throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let processor = GatedFailureImageProcessor()
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        imageProcessor: processor,
        configuration: .init(maximumReadRetryAttempts: 3)
    )
    let unreadableFileItem = NSPasteboardItem()
    let unavailableProvider = UnavailablePasteboardDataProvider()
    unreadableFileItem.setDataProvider(unavailableProvider, forTypes: [.fileURL])
    let imageItem = NSPasteboardItem()
    #expect(imageItem.setData(Data([9]), forType: .png))

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([unreadableFileItem, imageItem]))
    store.pollPasteboard()
    await processor.waitUntilStarted()
    store.pollPasteboard()

    await processor.release()
    await store.waitForPendingImageCapture()

    #expect(store.captureWarning == L10n.string("检测到图片，但格式无法解析。"))
    withExtendedLifetime(unavailableProvider) {}
}

@Test @MainActor
func successfulImageInTheSameBatchDoesNotHideAnotherImageFailure() async throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let processor = FailureBeforeSuccessImageProcessor(
        thumbnailData: try fileTestImageData(type: .png)
    )
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        imageProcessor: processor
    )
    let failingItem = NSPasteboardItem()
    #expect(failingItem.setData(Data([1]), forType: .png))
    let succeedingItem = NSPasteboardItem()
    #expect(succeedingItem.setData(Data([2]), forType: .png))

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([failingItem, succeedingItem]))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    #expect(store.items.filter { $0.image != nil }.count == 1)
    #expect(store.captureWarning == L10n.string("检测到图片，但格式无法解析。"))
}

@Test @MainActor
func copyingFilesWritesSeparateFileURLPasteboardItems() throws {
    let fixture = try FileFixture()
    defer { fixture.remove() }
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([
        fixture.fileURL as NSURL,
        fixture.folderURL as NSURL
    ]))
    store.pollPasteboard()
    let item = try #require(store.items.first)

    pasteboard.clearContents()
    #expect(pasteboard.setString("will be replaced", forType: .string))
    #expect(store.copy(item))

    let copiedURLs = try #require(pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
    ) as? [NSURL]).map { ($0 as URL).standardizedFileURL }
    #expect(copiedURLs == [fixture.fileURL, fixture.folderURL].map(\.standardizedFileURL))
    #expect(pasteboard.pasteboardItems?.count == 2)
}

@Test @MainActor
func missingFileDoesNotClearCurrentPasteboard() throws {
    let fixture = try FileFixture()
    defer { fixture.remove() }
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([fixture.fileURL as NSURL]))
    store.pollPasteboard()
    let item = try #require(store.items.first)
    try FileManager.default.removeItem(at: fixture.fileURL)

    pasteboard.clearContents()
    #expect(pasteboard.setString("keep me", forType: .string))
    let changeCountBeforeCopy = pasteboard.changeCount

    #expect(!store.copy(item))
    #expect(pasteboard.changeCount == changeCountBeforeCopy)
    #expect(pasteboard.string(forType: .string) == "keep me")
    #expect(store.captureWarning?.contains(fixture.fileURL.lastPathComponent) == true)
}

@Test
func fileGroupsDeduplicateRegardlessOfSelectionOrder() throws {
    let first = URL(fileURLWithPath: "/tmp/ClipDeck First.txt")
    let second = URL(fileURLWithPath: "/tmp/ClipDeck Second.txt")
    let left = try #require(ClipboardFileList(urls: [first, second]))
    let right = try #require(ClipboardFileList(urls: [second, first]))

    #expect(ClipboardItem(files: left).hasSameContent(as: ClipboardItem(files: right)))
    #expect(ClipboardItem(files: left).searchableText.contains("clipdeck first.txt"))
}

@Test @MainActor
func corruptPNGFallsBackToValidTIFF() async throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )

    pasteboard.clearContents()
    #expect(pasteboard.setData(Data("not png".utf8), forType: .png))
    #expect(pasteboard.setData(
        try fileTestImageData(type: .tiff),
        forType: .tiff
    ))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    #expect(store.items.first?.image != nil)
    #expect(store.captureWarning == nil)
}

@Test @MainActor
func validThirdCandidateIsNotReplacedByTIFF() async throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        configuration: .init(maximumSnapshotCandidateCount: 3)
    )
    let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
    let heicType = NSPasteboard.PasteboardType(UTType.heic.identifier)

    pasteboard.clearContents()
    #expect(pasteboard.setData(Data("bad png".utf8), forType: .png))
    #expect(pasteboard.setData(Data("bad jpeg".utf8), forType: jpegType))
    #expect(pasteboard.setData(try fileTestImageData(type: .png), forType: heicType))
    #expect(pasteboard.setData(Data("bad tiff".utf8), forType: .tiff))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    #expect(store.items.first?.image != nil)
    #expect(store.captureWarning == nil)
}

@Test @MainActor
func tiffFallbackGetsAnExtraSlotBeyondTheCandidateLimit() async throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        configuration: .init(maximumSnapshotCandidateCount: 1)
    )
    let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    pasteboard.clearContents()
    #expect(pasteboard.setData(Data("bad png".utf8), forType: .png))
    #expect(pasteboard.setData(Data("bad jpeg".utf8), forType: jpegType))
    #expect(pasteboard.setData(try fileTestImageData(type: .tiff), forType: .tiff))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    #expect(store.items.first?.image != nil)
    #expect(store.captureWarning == nil)
}

@Test @MainActor
func oversizedPrimaryImageFallsBackToALaterValidRepresentation() async throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )
    var oversizedPNG = try fileTestImageData(type: .png)
    oversizedPNG.append(Data(
        repeating: 0,
        count: ClipboardImageSafetyLimits.maximumFinalBytes
    ))
    let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    pasteboard.clearContents()
    #expect(pasteboard.setData(oversizedPNG, forType: .png))
    #expect(pasteboard.setData(try fileTestImageData(type: .jpeg), forType: jpegType))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    #expect(store.items.first?.image?.pasteboardType == jpegType)
    #expect(store.captureWarning == nil)
}

@Test @MainActor
func imageSnapshotByteLimitRejectsTheEventBeforeQueueing() throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        configuration: .init(maximumImageSnapshotBytes: 2)
    )

    pasteboard.clearContents()
    #expect(pasteboard.setData(Data([1, 2, 3]), forType: .png))
    store.pollPasteboard()

    #expect(store.items.isEmpty)
    #expect(store.captureWarning?.contains("2") == true)
}

@Test @MainActor
func unreadableImageFallsBackToItsTextRepresentation() async throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )

    pasteboard.clearContents()
    #expect(pasteboard.setString("Readable fallback", forType: .string))
    #expect(pasteboard.setData(Data("not an image".utf8), forType: .png))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    #expect(store.items.first?.text == "Readable fallback")
    #expect(store.captureWarning == L10n.string("图片无法解析，已保留可读取的文字和文字格式。"))
    #expect(store.items.first?.captureNote != nil)
}

@Test @MainActor
func copiedJPEGAlsoPublishesPNGCompatibilityData() async throws {
    let pasteboard = fileTestPasteboard()
    let defaults = try fileTestDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )
    let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    pasteboard.clearContents()
    #expect(pasteboard.setData(
        try fileTestImageData(type: .jpeg),
        forType: jpegType
    ))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()
    let item = try #require(store.items.first)

    #expect(store.copy(item))
    #expect(pasteboard.data(forType: jpegType) != nil)
    let pngData = try #require(pasteboard.data(forType: .png))
    #expect(NSImage(data: pngData) != nil)
    let tiffData = try #require(pasteboard.data(forType: .tiff))
    #expect(NSImage(data: tiffData) != nil)
}

@Test @MainActor
func nonstandardImageIsRejectedWhenNoCompatibleRepresentationCanBeMade() async throws {
    let jpegData = try fileTestImageData(type: .jpeg)
    let processor = ImageProcessor(
        configuration: .init(maximumCompatibilityBytes: 1)
    )
    let outcome = await processor.process(
        ImageProcessingCandidate(
            typeIdentifier: UTType.jpeg.identifier,
            data: jpegData
        )
    )

    switch outcome {
    case .failure(.compatibilityEncodingFailed):
        break
    default:
        Issue.record("Expected capture to require a compatible PNG or TIFF representation")
    }
}

@MainActor
private func fileTestPasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("ClipDeckFileTests.\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    return pasteboard
}

private func fileTestDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "ClipDeckFileTests.defaults.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(true, forKey: "monitoring")
    return (defaults, suiteName)
}

@MainActor
private func fileTestImageData(type: NSBitmapImageRep.FileType) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 12,
        pixelsHigh: 8,
        bitsPerSample: 8,
        samplesPerPixel: type == .jpeg ? 3 : 4,
        hasAlpha: type != .jpeg,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 12 * (type == .jpeg ? 3 : 4),
        bitsPerPixel: (type == .jpeg ? 3 : 4) * 8
    ))
    return try #require(bitmap.representation(using: type, properties: [:]))
}

private struct FileFixture {
    let rootURL: URL
    let fileURL: URL
    let folderURL: URL

    init() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDeckFileTests-\(UUID().uuidString)", isDirectory: true)
        let folderURL = rootURL.appendingPathComponent("Folder", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("Example.txt", isDirectory: false)
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: fileURL)
        self.rootURL = rootURL
        self.fileURL = fileURL
        self.folderURL = folderURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class UnavailablePasteboardDataProvider: NSObject,
    NSPasteboardItemDataProvider {
    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {}
}

private actor CountingGatedImageProcessor: ImageProcessing {
    private let thumbnailData: Data
    private var continuation: CheckedContinuation<Void, Never>?
    private var callCount = 0

    init(thumbnailData: Data) {
        self.thumbnailData = thumbnailData
    }

    func process(_ candidate: ImageProcessingCandidate) async -> ImageProcessingOutcome {
        callCount += 1
        if callCount == 1 {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return .success(
            ProcessedClipboardImage(
                data: candidate.data,
                typeIdentifier: UTType.png.identifier,
                pixelWidth: 12,
                pixelHeight: 8,
                fingerprint: candidate.data,
                thumbnailData: thumbnailData
            )
        )
    }

    func waitUntilStarted() async {
        while callCount == 0 || continuation == nil {
            await Task.yield()
        }
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    func numberOfCalls() -> Int {
        callCount
    }
}

private actor FailureBeforeSuccessImageProcessor: ImageProcessing {
    private let thumbnailData: Data
    private var hasFailed = false

    init(thumbnailData: Data) {
        self.thumbnailData = thumbnailData
    }

    func process(_ candidate: ImageProcessingCandidate) async -> ImageProcessingOutcome {
        if candidate.data.first == 1 {
            hasFailed = true
            return .failure(.invalidFormat)
        }

        while !hasFailed {
            await Task.yield()
        }
        return .success(
            ProcessedClipboardImage(
                data: candidate.data,
                typeIdentifier: UTType.png.identifier,
                pixelWidth: 12,
                pixelHeight: 8,
                fingerprint: candidate.data,
                thumbnailData: thumbnailData
            )
        )
    }
}

private actor GatedFailureImageProcessor: ImageProcessing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func process(_ candidate: ImageProcessingCandidate) async -> ImageProcessingOutcome {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return .failure(.invalidFormat)
    }

    func waitUntilStarted() async {
        while !hasStarted || continuation == nil {
            await Task.yield()
        }
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}
