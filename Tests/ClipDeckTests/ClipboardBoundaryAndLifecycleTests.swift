import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipDeck

@Suite(.serialized) @MainActor
struct ClipboardBoundaryAndLifecycleTests {
    @Test func nativeURLAndHTMLAreCapturedWithTheirOriginalFormats() async throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        fixture.write([URL(string: "https://example.com/path?q=test")! as NSURL])
        fixture.store.requestPasteboardCapture()
        await fixture.store.waitForPendingImageCapture()
        let url = try #require(fixture.store.items.first)
        #expect(url.text == "https://example.com/path?q=test")
        #expect(fixture.store.copy(url))
        #expect(fixture.pasteboard.string(forType: .URL) == "https://example.com/path?q=test")

        let html = "<p>Hello <b>world</b> &amp; &#x1f600;</p><script>doNotInclude()</script>"
        let source = NSPasteboardItem()
        source.setString(html, forType: .html)
        fixture.write([source])
        fixture.store.requestPasteboardCapture()
        await fixture.store.waitForPendingImageCapture()
        let item = try #require(fixture.store.items.first)
        #expect(item.text == "Hello world & 😀\n")
        #expect(item.hasRichText)
        #expect(fixture.store.copy(item))
        #expect(fixture.pasteboard.string(forType: .html) == html)
        #expect(fixture.store.copy(item, plainTextOnly: true))
        #expect(fixture.pasteboard.string(forType: .string) == "Hello world & 😀\n")
        #expect(fixture.pasteboard.data(forType: .html) == nil)
    }

    @Test func richTextPreservesFormattingAndFormattingChangesDoNotDeduplicate() throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        let first = NSAttributedString(string: "Same words", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        let second = NSAttributedString(string: "Same words", attributes: [.font: NSFont.systemFont(ofSize: 10)])
        fixture.write([first])
        fixture.store.pollPasteboard()
        let captured = try #require(fixture.store.items.first)
        let rtf = try #require(fixture.pasteboard.data(forType: .rtf))
        fixture.write([second])
        fixture.store.pollPasteboard()
        #expect(fixture.store.items.count == 2)
        #expect(fixture.store.copy(captured))
        #expect(fixture.pasteboard.data(forType: .rtf) == rtf)
    }

    @Test func URLThenIdenticalPlainTextDoesNotDiscardTheURLRepresentation() throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        let value = "https://example.com/retained-url"
        fixture.write([URL(string: value)! as NSURL])
        fixture.store.pollPasteboard()
        let urlItem = try #require(fixture.store.items.first)
        fixture.write([boundaryText(value)])
        fixture.store.pollPasteboard()
        #expect(fixture.store.items.count == 2)
        #expect(fixture.store.copy(urlItem))
        #expect(fixture.pasteboard.string(forType: .URL) == value)
    }

    @Test func oneEventKeepsTextFilesAndImagesInOriginalOrder() async throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        let image = NSPasteboardItem()
        image.setData(try boundaryPNG(), forType: .png)
        let file = URL(fileURLWithPath: #filePath).standardizedFileURL
        fixture.write([boundaryText("First"), file as NSURL, image, boundaryText("Last")])
        fixture.store.requestPasteboardCapture()
        await fixture.store.waitForPendingImageCapture()
        #expect(fixture.store.items.count == 1)
        let item = try #require(fixture.store.items.first)
        #expect(item.parts.count == 4)
        #expect(item.plainText == "First\nLast")
        #expect(fixture.store.copy(item))
        let originals = try #require(fixture.pasteboard.pasteboardItems)
        #expect(originals.count == 4)
        #expect(originals[0].string(forType: .string) == "First")
        #expect(originals[1].string(forType: .fileURL) == file.absoluteString)
        #expect(originals[2].data(forType: .png) != nil)
        #expect(originals[3].string(forType: .string) == "Last")
    }

    @Test func PDFArtworkIsCapturedAndReplayedAsTheOriginalPDF() async throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 120, height: 80)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(bounds)
        context.endPDFPage()
        context.closePDF()
        let source = NSPasteboardItem()
        source.setData(data as Data, forType: .pdf)
        source.setData(try boundaryPNG(), forType: .png)
        fixture.write([source])
        fixture.store.requestPasteboardCapture()
        await fixture.store.waitForPendingImageCapture()
        let item = try #require(fixture.store.items.first)
        #expect(item.image?.pasteboardType == .pdf)
        #expect(item.image?.data == data as Data)
        #expect(fixture.store.copy(item))
        #expect(fixture.pasteboard.data(forType: .pdf) == data as Data)
        #expect(fixture.pasteboard.data(forType: .png) != nil)
    }

    @Test func imageQueueMemoryPressureDoesNotPreventTextCapture() async throws {
        let data = try boundaryPNG()
        let processor = BoundaryGatedImageProcessor()
        let fixture = try BoundaryFixture(configuration: .init(maximumPendingImageCaptureBytes: data.count), imageProcessor: processor)
        defer { fixture.close() }
        let source = NSPasteboardItem()
        source.setData(data, forType: .png)
        fixture.write([source])
        fixture.store.pollPasteboard()
        await processor.waitUntilStarted()
        fixture.write([boundaryText("Text while image queue is full")])
        fixture.store.pollPasteboard()
        #expect(fixture.store.items.first?.text == "Text while image queue is full")
        await processor.release()
        await fixture.store.waitForPendingImageCapture()
        #expect(fixture.store.items.count == 2)
    }

    @Test func derivedImagesInOneEventAreBoundedBeforePublishingHistory() async throws {
        let data = try boundaryPNG()
        let processed = await ImageProcessor().process(.init(typeIdentifier: UTType.png.identifier, data: data))
        guard case .success(let image) = processed else { Issue.record("PNG fixture should decode"); return }
        let singleImageBytes = data.count + image.thumbnailData.count + (image.previewData?.count ?? 0)
        let fixture = try BoundaryFixture(configuration: .init(maximumImageHistoryBytes: singleImageBytes + 1))
        defer { fixture.close() }
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setData(data, forType: .png)
        second.setData(data, forType: .png)
        fixture.write([first, second])
        fixture.store.pollPasteboard()
        await fixture.store.waitForPendingImageCapture()
        let item = try #require(fixture.store.items.first)
        #expect(item.parts.count == 1)
        #expect(item.storageByteCount <= singleImageBytes + 1)
        #expect(item.captureNote != nil)
        #expect(fixture.store.captureWarning != nil)
    }

    @Test func deletingAPartialEventPreventsItsLateImageFromResurrectingIt() async throws {
        let processor = BoundaryGatedImageProcessor()
        let fixture = try BoundaryFixture(imageProcessor: processor)
        defer { fixture.close() }
        fixture.pasteboard.declareTypes([.string, .png], owner: nil)
        fixture.pasteboard.setString("Initially only text is readable", forType: .string)
        fixture.store.pollPasteboard()
        let partial = try #require(fixture.store.items.first)
        let count = fixture.pasteboard.changeCount
        fixture.pasteboard.setData(try boundaryPNG(), forType: .png)
        #expect(fixture.pasteboard.changeCount == count)
        fixture.store.pollPasteboard()
        await processor.waitUntilStarted()
        fixture.store.delete(partial)
        await processor.release()
        await fixture.store.waitForPendingImageCapture()
        #expect(fixture.store.items.isEmpty)
    }

    @Test func explicitWhitespaceIsRetainedExactly() throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        for value in ["", "   ", "\n\t\n"] {
            fixture.write([boundaryText(value)])
            fixture.store.pollPasteboard()
            let item = try #require(fixture.store.items.first)
            #expect(item.text == value)
            #expect(fixture.store.copy(item))
            #expect(fixture.pasteboard.string(forType: .string) == value)
        }
    }

    @Test func UTF16OnlyClipboardTextUsesTheSystemPlainTextConversion() async throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        let source = NSPasteboardItem()
        source.setData("有效的 UTF16 text".data(using: .utf16)!, forType: .init("public.utf16-external-plain-text"))
        fixture.write([source])
        fixture.store.requestPasteboardCapture()
        await fixture.store.waitForPendingImageCapture()
        #expect(fixture.store.items.first?.text == "有效的 UTF16 text")
    }

    @Test func groupedPlainTextSharesTheTotalHistoryByteBudget() throws {
        let fixture = try BoundaryFixture(configuration: .init(maximumImageHistoryBytes: 16))
        defer { fixture.close() }
        fixture.write([boundaryText("AAAA"), boundaryText("BBBB")])
        fixture.store.pollPasteboard()
        #expect(fixture.store.items.count == 1)
        fixture.write([boundaryText("CCCC"), boundaryText("DDDD")])
        fixture.store.pollPasteboard()
        #expect(fixture.store.items.count == 1)
        #expect(fixture.store.items.first?.plainText == "CCCC\nDDDD")
        #expect(fixture.store.items.reduce(0) { $0 + $1.storageByteCount } <= 16)
    }

    @Test func anOlderSnapshotDoesNotMakeAManualCopyBecomeANewHistoryEvent() async throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        fixture.write([boundaryText("Older history")])
        fixture.store.pollPasteboard()
        let older = try #require(fixture.store.items.first)
        fixture.write([boundaryText("Newer history")])
        fixture.store.pollPasteboard()
        fixture.write([boundaryText("External observed event")])
        fixture.store.requestPasteboardCapture()
        await Task.yield()
        #expect(fixture.store.copy(older))
        await fixture.store.waitForPendingImageCapture()
        fixture.store.requestPasteboardCapture()
        await fixture.store.waitForPendingImageCapture()
        #expect(fixture.store.items.last?.id == older.id)
        #expect(fixture.store.items.filter { $0.text == "Older history" }.count == 1)
    }

    @Test func unknownItemsProduceAnExplicitPersistentPartialNotice() throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        let custom = NSPasteboardItem()
        custom.setData(Data([1, 2]), forType: .init("com.example.private-object"))
        fixture.write([boundaryText("Readable"), custom])
        let count = fixture.pasteboard.changeCount
        fixture.store.pollPasteboard()
        #expect(fixture.store.items.count == 1)
        #expect(fixture.store.items.first?.text == "Readable")
        #expect(fixture.store.items.first?.captureNote != nil)
        #expect(fixture.store.captureWarning != nil)
        #expect(fixture.pasteboard.changeCount == count)
        fixture.write([boundaryText("Later")])
        fixture.store.pollPasteboard()
        #expect(fixture.store.items.last?.captureNote != nil)
    }

    @Test func clearingHistoryInvalidatesOnlyHistoryUndo() throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        let manager = UndoManager()
        manager.groupsByEvent = false
        let marker = OrdinaryUndoMarker()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: marker, selector: #selector(OrdinaryUndoMarker.apply(_:)), object: nil)
        manager.endUndoGrouping()
        fixture.write([boundaryText("Remove forever")])
        fixture.store.pollPasteboard()
        fixture.store.delete(try #require(fixture.store.items.first), undoManager: manager)
        fixture.store.clearHistory()
        #expect(manager.canUndo)
        manager.undo()
        #expect(marker.applied)
        #expect(fixture.store.items.isEmpty)
        #expect(!manager.canUndo)
    }

    @Test func undoRetentionHasIndependentCountAndByteLimits() throws {
        let fixture = try BoundaryFixture(configuration: .init(maximumUndoItemCount: 2, maximumUndoBytes: 8))
        defer { fixture.close() }
        let manager = UndoManager()
        manager.groupsByEvent = false
        for value in ["AA", "BB", "CC"] {
            let item = ClipboardItem(text: value)
            fixture.store.restore(item, at: 0)
            fixture.store.delete(item, undoManager: manager)
        }
        manager.undo()
        manager.undo()
        #expect(Set(fixture.store.items.compactMap(\.text)) == Set(["BB", "CC"]))
        #expect(!manager.canUndo)
        let huge = ClipboardItem(text: "123456789")
        fixture.store.restore(huge, at: 0)
        fixture.store.delete(huge, undoManager: manager)
        #expect(!manager.canUndo)
        #expect(fixture.store.captureWarning != nil)
    }

    @Test func providerSnapshotsUseTheMainActorAppKitBoundary() async throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        let provider = SlowBoundaryProvider()
        let source = NSPasteboardItem()
        source.setDataProvider(provider, forTypes: [.string])
        fixture.write([source])
        fixture.store.requestPasteboardCapture()
        await fixture.store.waitForPendingImageCapture()
        #expect(fixture.store.items.first?.text == "Slow source")
        #expect(!provider.wasReadOffMain)
        #expect(provider.readCount == 1)
        withExtendedLifetime(provider) {}
    }

    @Test func clearingBeforeAScheduledSnapshotPreventsTheProviderRead() async throws {
        let fixture = try BoundaryFixture()
        defer { fixture.close() }
        let provider = SlowBoundaryProvider()
        let source = NSPasteboardItem()
        source.setDataProvider(provider, forTypes: [.string])
        fixture.write([source])
        fixture.store.requestPasteboardCapture()
        fixture.store.clearHistory()
        await fixture.store.waitForPendingImageCapture()
        #expect(fixture.store.items.isEmpty)
        #expect(provider.readCount == 0)
        withExtendedLifetime(provider) {}
    }
}

@MainActor
private struct BoundaryFixture {
    let pasteboard: NSPasteboard
    let defaults: UserDefaults
    let suite: String
    let store: ClipboardStore
    init(configuration: ClipboardStore.Configuration = .default, imageProcessor: any ImageProcessing = ImageProcessor()) throws {
        suite = "ClipDeckBoundaryTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "monitoring")
        pasteboard = NSPasteboard(name: .init(suite))
        store = ClipboardStore(pasteboard: pasteboard, startsMonitoring: false, performsLegacyCleanup: false,
            userDefaults: defaults, monitoringDefaultsKey: "monitoring", imageProcessor: imageProcessor, configuration: configuration)
    }
    func write(_ objects: [NSPasteboardWriting]) {
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects(objects))
    }
    func close() {
        defaults.removePersistentDomain(forName: suite)
        pasteboard.releaseGlobally()
    }
}

@MainActor private func boundaryText(_ value: String) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(value, forType: .string)
    return item
}

@MainActor private func boundaryPNG() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 48, bitsPerPixel: 32))
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@MainActor private final class OrdinaryUndoMarker: NSObject {
    var applied = false
    @objc func apply(_ sender: Any?) { applied = true }
}

private final class SlowBoundaryProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var offMain = false
    private var calls = 0
    var wasReadOffMain: Bool { lock.withLock { offMain } }
    var readCount: Int { lock.withLock { calls } }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.withLock { offMain = !Thread.isMainThread; calls += 1 }
        Thread.sleep(forTimeInterval: 0.3)
        item.setString("Slow source", forType: type)
    }
}

private actor BoundaryGatedImageProcessor: ImageProcessing {
    private var continuation: CheckedContinuation<Void, Never>?
    func process(_ candidate: ImageProcessingCandidate) async -> ImageProcessingOutcome {
        await withCheckedContinuation { continuation = $0 }
        return await ImageProcessor().process(candidate)
    }
    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
