import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ClipDeck

@Test @MainActor
func monitoringPreferenceSurvivesStoreRecreation() throws {
    let suiteName = "ClipDeckTests.preferences.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let key = "monitoring"
    defaults.set(true, forKey: key)

    let firstStore = ClipboardStore(
        pasteboard: isolatedPasteboard(),
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults,
        monitoringDefaultsKey: key
    )
    #expect(firstStore.isMonitoring)

    firstStore.isMonitoring = false
    #expect(!defaults.bool(forKey: key))

    let recreatedStore = ClipboardStore(
        pasteboard: isolatedPasteboard(),
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults,
        monitoringDefaultsKey: key
    )
    #expect(!recreatedStore.isMonitoring)
}

@Test @MainActor
func oversizedTextIsRejectedWithAVisibleWarning() throws {
    let pasteboard = isolatedPasteboard()
    let defaults = try enabledDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        configuration: .init(maximumTextBytes: 4)
    )

    pasteboard.clearContents()
    #expect(pasteboard.setString("12345", forType: .string))
    store.pollPasteboard()

    #expect(store.items.isEmpty)
    #expect(store.captureWarning?.contains("4") == true)
    let maximumSize = ByteCountFormatter.string(fromByteCount: 4, countStyle: .file)
    #expect(store.captureWarning == L10n.string("文字超过 %@，未记录。", maximumSize))
}

@Test @MainActor
func historyTrimsPromotesExternalDuplicatesAndDoesNotReorderManualCopies() throws {
    let pasteboard = isolatedPasteboard()
    let defaults = try enabledDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        configuration: .init(maximumItemCount: 3)
    )

    for value in ["A", "B", "C", "D"] {
        pasteboard.clearContents()
        #expect(pasteboard.setString(value, forType: .string))
        store.pollPasteboard()
    }

    #expect(store.items.count == 3)
    #expect(store.items.map(\.text) == ["D", "C", "B"])

    let itemB = try #require(store.items.last)
    let originalOrder = store.items.map(\.id)
    #expect(store.copy(itemB))
    #expect(store.items.map(\.id) == originalOrder)

    pasteboard.clearContents()
    #expect(pasteboard.setString("B", forType: .string))
    store.pollPasteboard()
    #expect(store.items.first?.id == itemB.id)
    #expect(store.items.count == 3)

    let restoredItem = try #require(store.items.dropFirst().first)
    let restoredIndex = try #require(store.index(of: restoredItem))
    store.delete(restoredItem)
    #expect(!store.items.contains { $0.id == restoredItem.id })
    store.restore(restoredItem, at: restoredIndex)
    #expect(store.items[restoredIndex].id == restoredItem.id)
    #expect(store.items[restoredIndex].capturedAt == restoredItem.capturedAt)
}

@Test @MainActor
func damagedPreferredImageFallsBackToAValidRepresentation() async throws {
    let pasteboard = isolatedPasteboard()
    let defaults = try enabledDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )
    let pngData = try makePNG(width: 18, height: 12)
    let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    pasteboard.clearContents()
    #expect(pasteboard.setData(Data("not a jpeg".utf8), forType: jpegType))
    #expect(pasteboard.setData(pngData, forType: .png))
    store.pollPasteboard()
    await store.waitForPendingImageCapture()

    let image = try #require(store.items.first?.image)
    #expect(image.pasteboardType == .png)
    #expect(image.pixelWidth == 18)
    #expect(image.pixelHeight == 12)
    #expect(store.captureWarning == nil)
}

@Test @MainActor
func readFailuresAreBoundedAndRecoverOnTheNextClipboardChange() throws {
    let pasteboard = isolatedPasteboard()
    let defaults = try enabledDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        configuration: .init(maximumReadRetryAttempts: 3)
    )

    pasteboard.declareTypes([.string], owner: nil)
    store.pollPasteboard()
    #expect(
        store.captureWarning
            == L10n.string("检测到文字，但暂时无法读取；将自动重试。")
    )
    store.pollPasteboard()
    store.pollPasteboard()
    #expect(
        store.captureWarning
            == L10n.string("文字连续多次读取失败，本次未记录。")
    )

    pasteboard.clearContents()
    #expect(pasteboard.setString("恢复读取", forType: .string))
    store.pollPasteboard()
    #expect(store.items.first?.text == "恢复读取")
    #expect(store.captureWarning == nil)
}

@Test @MainActor
func aNewClipboardChangeWaitsForThePendingImageInsteadOfCancellingIt() async throws {
    let thumbnailData = try makePNG(width: 4, height: 4)
    let processed = ProcessedClipboardImage(
        data: Data([1, 2, 3]),
        typeIdentifier: UTType.png.identifier,
        pixelWidth: 4,
        pixelHeight: 4,
        fingerprint: Data([9]),
        thumbnailData: thumbnailData
    )
    let processor = GatedImageProcessor(output: processed)
    let pasteboard = isolatedPasteboard()
    let defaults = try enabledDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        imageProcessor: processor
    )

    pasteboard.clearContents()
    #expect(pasteboard.setData(Data([7]), forType: .png))
    store.pollPasteboard()
    await processor.waitUntilStarted()

    pasteboard.clearContents()
    #expect(pasteboard.setString("图片之后的新内容", forType: .string))
    store.pollPasteboard()
    await processor.release()
    await store.waitForPendingImageCapture()
    store.pollPasteboard()

    #expect(store.items.count == 2)
    #expect(store.items.first?.text == "图片之后的新内容")
    #expect(store.items.last?.image != nil)
}

@Test @MainActor
func imageHistoryByteBudgetKeepsTheNewestImageThatFits() throws {
    let defaults = try enabledDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: isolatedPasteboard(),
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        configuration: .init(maximumImageHistoryBytes: 5)
    )
    let thumbnailData = try makePNG(width: 2, height: 2)
    let olderImage = try makeClipboardImage(
        data: Data(repeating: 1, count: 4),
        fingerprint: Data([1]),
        thumbnailData: thumbnailData
    )
    let newerImage = try makeClipboardImage(
        data: Data(repeating: 2, count: 4),
        fingerprint: Data([2]),
        thumbnailData: thumbnailData
    )
    let olderItem = ClipboardItem(image: olderImage, copiedAt: Date(timeIntervalSince1970: 1))
    let newerItem = ClipboardItem(image: newerImage, copiedAt: Date(timeIntervalSince1970: 2))

    store.restore(olderItem, at: 0)
    store.restore(newerItem, at: 0)

    #expect(store.items.map(\.id) == [newerItem.id])
}

@Test @MainActor
func deletingAnItemSupportsUndoAndRedo() throws {
    let defaults = try enabledDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: isolatedPasteboard(),
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring"
    )
    let item = ClipboardItem(text: "可撤销")
    store.restore(item, at: 0)
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false

    store.delete(item, undoManager: undoManager)
    #expect(store.items.isEmpty)
    #expect(undoManager.canUndo)

    undoManager.undo()
    #expect(store.items.first?.id == item.id)
    #expect(undoManager.canRedo)

    undoManager.redo()
    #expect(store.items.isEmpty)
    #expect(undoManager.canUndo)
}

@Test
func imageProcessorRejectsRawDataBeforeAttemptingToDecodeIt() async {
    let processor = ImageProcessor(
        configuration: .init(maximumRawBytes: 2)
    )
    let outcome = await processor.process(
        ImageProcessingCandidate(
            typeIdentifier: UTType.png.identifier,
            data: Data([1, 2, 3])
        )
    )

    switch outcome {
    case .failure(.rawDataTooLarge):
        break
    default:
        Issue.record("Expected the raw byte guard to reject before decoding")
    }
}

@Test @MainActor
func manuallyCopyingHistoryDoesNotCancelAnObservedExternalImage() async throws {
    let thumbnailData = try makePNG(width: 4, height: 4)
    let processed = ProcessedClipboardImage(
        data: Data([4, 5, 6]),
        typeIdentifier: UTType.png.identifier,
        pixelWidth: 4,
        pixelHeight: 4,
        fingerprint: Data([4, 5, 6]),
        thumbnailData: thumbnailData
    )
    let processor = GatedImageProcessor(output: processed)
    let pasteboard = isolatedPasteboard()
    let defaults = try enabledDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        imageProcessor: processor
    )

    pasteboard.clearContents()
    #expect(pasteboard.setString("已有历史", forType: .string))
    store.pollPasteboard()
    let existingItem = try #require(store.items.first)

    pasteboard.clearContents()
    #expect(pasteboard.setData(Data([7]), forType: .png))
    store.pollPasteboard()
    await processor.waitUntilStarted()

    #expect(store.copy(existingItem))
    await processor.release()
    await store.waitForPendingImageCapture()

    #expect(store.items.count == 2)
    #expect(store.items.contains { $0.id == existingItem.id })
    #expect(store.items.contains { $0.image?.data == processed.data })
}

@Test @MainActor
func multipleObservedImagesQueueWhileTheFirstImageIsSlow() async throws {
    let thumbnailData = try makePNG(width: 3, height: 3)
    let processor = FirstCallGatedImageProcessor(thumbnailData: thumbnailData)
    let pasteboard = isolatedPasteboard()
    let defaults = try enabledDefaults()
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }
    let store = ClipboardStore(
        pasteboard: pasteboard,
        startsMonitoring: false,
        performsLegacyCleanup: false,
        userDefaults: defaults.defaults,
        monitoringDefaultsKey: "monitoring",
        imageProcessor: processor
    )

    for byte in UInt8(1)...UInt8(3) {
        pasteboard.clearContents()
        #expect(pasteboard.setData(Data([byte]), forType: .png))
        store.pollPasteboard()
        if byte == 1 {
            await processor.waitUntilFirstCallStarted()
        }
    }

    await processor.releaseFirstCall()
    await store.waitForPendingImageCapture()

    #expect(store.items.count == 3)
    #expect(Set(store.items.compactMap { $0.image?.data.first }) == Set([1, 2, 3]))
}

@Test
func imageProcessorUsesTheDetectedEncodingInsteadOfAMislabeledPasteboardType() async throws {
    let pngData = await MainActor.run {
        try? makePNG(width: 6, height: 5)
    }
    let candidateData = try #require(pngData)
    let processor = ImageProcessor()
    let outcome = await processor.process(
        ImageProcessingCandidate(
            typeIdentifier: UTType.tiff.identifier,
            data: candidateData
        )
    )

    switch outcome {
    case .success(let image):
        #expect(image.typeIdentifier == UTType.png.identifier)
        #expect(image.pixelWidth == 6)
        #expect(image.pixelHeight == 5)
    default:
        Issue.record("Expected mislabeled PNG data to be detected and retained as PNG")
    }
}

private actor GatedImageProcessor: ImageProcessing {
    private let output: ProcessedClipboardImage
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    init(output: ProcessedClipboardImage) {
        self.output = output
    }

    func process(_ candidate: ImageProcessingCandidate) async -> ImageProcessingOutcome {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return .success(output)
    }

    func waitUntilStarted() async {
        while !hasStarted {
            await Task.yield()
        }
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private actor FirstCallGatedImageProcessor: ImageProcessing {
    private let thumbnailData: Data
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var callCount = 0

    init(thumbnailData: Data) {
        self.thumbnailData = thumbnailData
    }

    func process(_ candidate: ImageProcessingCandidate) async -> ImageProcessingOutcome {
        callCount += 1
        if callCount == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }

        return .success(
            ProcessedClipboardImage(
                data: candidate.data,
                typeIdentifier: UTType.png.identifier,
                pixelWidth: 3,
                pixelHeight: 3,
                fingerprint: candidate.data,
                thumbnailData: thumbnailData
            )
        )
    }

    func waitUntilFirstCallStarted() async {
        while callCount == 0 || firstContinuation == nil {
            await Task.yield()
        }
    }

    func releaseFirstCall() {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private func isolatedPasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name("ClipDeckTests.\(UUID().uuidString)")
    )
    pasteboard.clearContents()
    return pasteboard
}

private func enabledDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "ClipDeckTests.defaults.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(true, forKey: "monitoring")
    return (defaults, suiteName)
}

@MainActor
private func makePNG(width: Int, height: Int) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: width * 4,
        bitsPerPixel: 32
    ))
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@MainActor
private func makeClipboardImage(
    data: Data,
    fingerprint: Data,
    thumbnailData: Data
) throws -> ClipboardImage {
    try #require(ClipboardImage(processed: ProcessedClipboardImage(
        data: data,
        typeIdentifier: UTType.png.identifier,
        pixelWidth: 2,
        pixelHeight: 2,
        fingerprint: fingerprint,
        thumbnailData: thumbnailData
    )))
}
