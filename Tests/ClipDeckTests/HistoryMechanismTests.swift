import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ClipDeck

@Suite(.serialized) @MainActor
struct HistoryMechanismTests {
    private let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    // MARK: Memory budget

    @Test func olderImagesReleaseRebuildableRastersBeforeBeingEvicted() async throws {
        let red = try mechanismJPEG(red: 255, blue: 0)
        let blue = try mechanismJPEG(red: 0, blue: 255)
        let (redFull, redCompact) = try await measuredStorage(of: red)
        let (blueFull, blueCompact) = try await measuredStorage(of: blue)
        #expect(redCompact < redFull && blueCompact < blueFull)
        let budget = max(redFull, blueFull) + max(redCompact, blueCompact) + 1_024
        try #require(budget < redFull + blueFull, "Fixture images must not fit together at full size")

        let fixture = try MechanismFixture(configuration: .init(maximumImageHistoryBytes: budget))
        defer { fixture.close() }
        for image in [red, blue] {
            fixture.write(data: image, type: jpegType)
            fixture.store.pollPasteboard()
            await fixture.store.waitForPendingImageCapture()
        }

        #expect(fixture.store.items.count == 2)
        let newest = try #require(fixture.store.items.first)
        let older = try #require(fixture.store.items.last)
        #expect(newest.hasRebuildableData)
        #expect(!older.hasRebuildableData)
        #expect(fixture.store.captureWarning == nil)
        #expect(fixture.store.items.reduce(0) { $0 + $1.storageByteCount } <= budget)

        // Copying the compacted item rebuilds PNG and TIFF right after the JPEG.
        #expect(fixture.store.copy(older))
        let restored = try #require(fixture.pasteboard.pasteboardItems?.first)
        #expect(restored.types.filter { $0 != restoreTokenPasteboardType } == [jpegType, .png, .tiff])
        #expect(restored.data(forType: jpegType) == red)
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let image = try #require(restored.data(forType: type).flatMap(NSBitmapImageRep.init(data:)))
            #expect(image.pixelsWide == 64)
            #expect(image.pixelsHigh == 48)
        }
    }

    @Test func undoKeepsOnlyOriginalImageDataAndCopyRebuildsTheRest() async throws {
        let fixture = try MechanismFixture()
        defer { fixture.close() }
        fixture.write(data: try mechanismJPEG(red: 0, blue: 255), type: jpegType)
        fixture.store.pollPasteboard()
        await fixture.store.waitForPendingImageCapture()
        let item = try #require(fixture.store.items.first)
        #expect(item.hasRebuildableData)
        let manager = UndoManager()
        manager.groupsByEvent = false

        fixture.store.delete(item, undoManager: manager)
        manager.undo()

        let restoredItem = try #require(fixture.store.items.first)
        #expect(restoredItem.id == item.id)
        #expect(!restoredItem.hasRebuildableData)
        #expect(fixture.store.copy(restoredItem))
        #expect(fixture.pasteboard.data(forType: .png).flatMap(NSImage.init(data:)) != nil)
        #expect(fixture.pasteboard.data(forType: .tiff).flatMap(NSImage.init(data:)) != nil)
    }

    // MARK: Ordering

    @Test func undoRestoresByCaptureTimeBelowNewerItems() throws {
        let fixture = try MechanismFixture()
        defer { fixture.close() }
        let first = ClipboardItem(text: "A", copiedAt: Date(timeIntervalSince1970: 1))
        let second = ClipboardItem(text: "B", copiedAt: Date(timeIntervalSince1970: 2))
        fixture.store.restore(first)
        fixture.store.restore(second)
        let manager = UndoManager()
        manager.groupsByEvent = false

        fixture.store.delete(first, undoManager: manager)
        fixture.store.restore(ClipboardItem(text: "C", copiedAt: Date(timeIntervalSince1970: 3)))
        manager.undo()

        #expect(fixture.store.items.map(\.text) == ["C", "B", "A"])
    }

    @Test func aNewerCopyOfDeletedContentWinsOverUndo() throws {
        let fixture = try MechanismFixture()
        defer { fixture.close() }
        let original = ClipboardItem(text: "Same", copiedAt: Date(timeIntervalSince1970: 1))
        fixture.store.restore(original)
        fixture.store.restore(ClipboardItem(text: "Other", copiedAt: Date(timeIntervalSince1970: 2)))
        let manager = UndoManager()
        manager.groupsByEvent = false

        fixture.store.delete(original, undoManager: manager)
        let newer = ClipboardItem(text: "Same", copiedAt: Date(timeIntervalSince1970: 3))
        fixture.store.restore(newer)
        manager.undo()

        #expect(fixture.store.items.first?.id == newer.id)
        #expect(fixture.store.items.map(\.text) == ["Same", "Other"])
    }

    // MARK: Search

    @Test func searchMatchesEveryTermInAnyOrder() throws {
        let fixture = try MechanismFixture()
        defer { fixture.close() }
        for (index, text) in ["Deploy to staging now", "staging cluster", "deploy prod", "Café menu"].enumerated() {
            fixture.store.restore(ClipboardItem(text: text, copiedAt: Date(timeIntervalSince1970: Double(index))))
        }

        #expect(fixture.store.filteredItems(matching: "staging deploy").map(\.text) == ["Deploy to staging now"])
        #expect(fixture.store.filteredItems(matching: "STAGING").count == 2)
        #expect(fixture.store.filteredItems(matching: "ＤＥＰＬＯＹ").count == 2)
        #expect(fixture.store.filteredItems(matching: "cafe").map(\.text) == ["Café menu"])
        #expect(fixture.store.filteredItems(matching: "  \n").count == 4)
        #expect(fixture.store.filteredItems(matching: "staging missing").isEmpty)
    }

    @Test func groupedPartsDoNotMatchAcrossTheirBoundary() {
        let item = ClipboardItem(parts: [.text("alpha"), .text("beta")])
        #expect(!ClipboardSearchQuery("habe").matches(item))
        #expect(ClipboardSearchQuery("alpha beta").matches(item))
        #expect(ClipboardSearchQuery.contains("abc", ""))
        #expect(!ClipboardSearchQuery.contains("", "a"))
    }

    // MARK: Time

    @Test func timestampsNameTheDayOutsideToday() throws {
        let calendar = Calendar.current
        let now = Date()
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        #expect(ClipboardItem.timestampText(for: now, relativeTo: now) == time(now))

        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        #expect(ClipboardItem.timestampText(for: yesterday, relativeTo: now)
            == L10n.string("昨天 %@", time(yesterday)))

        let lastWeek = try #require(calendar.date(byAdding: .day, value: -8, to: now))
        let olderText = ClipboardItem.timestampText(for: lastWeek, relativeTo: now)
        #expect(olderText.hasSuffix(time(lastWeek)))
        #expect(olderText.count > time(lastWeek).count)
    }

    private func measuredStorage(of jpeg: Data) async throws -> (full: Int, compact: Int) {
        let probe = try MechanismFixture()
        defer { probe.close() }
        probe.write(data: jpeg, type: jpegType)
        probe.store.pollPasteboard()
        await probe.store.waitForPendingImageCapture()
        let item = try #require(probe.store.items.first)
        #expect(item.hasRebuildableData)
        return (item.storageByteCount, item.droppingRebuildableData().storageByteCount)
    }
}

@Suite struct HTMLTextExtractorTests {
    @Test func matchesTheDocumentedFallbackRules() {
        let cases: [(String, String)] = [
            ("<p>Hello <b>world</b> &amp; &#x1f600;</p><script>doNotInclude()</script>", "Hello world & 😀\n"),
            ("a<!-- hidden -->b", "ab"),
            ("a<!-- unclosed > c", "a c"),
            ("one<br>two<br/>three<BR class=\"x\">four", "one\ntwo\nthree\nfour"),
            ("<li>first</li><li>second</li>", "first\nsecond\n"),
            ("a < b", "a < b"),
            ("1 <> 2", "1 <> 2"),
            ("x < y and z >", "x "),
            ("<script>let unclosed = true; b", "let unclosed = true; b"),
            ("<STYLE type=\"text/css\">p{}</style >visible", "visible"),
            ("&lt;b&gt; stays literal", "<b> stays literal"),
            ("&unknown; &AMP; &#xD800; &#65;&#x42;", "&unknown; &AMP; &#xD800; AB"),
            ("&#99999999999999999999;", "&#99999999999999999999;"),
            ("<scripts>kept</scripts>", "kept")
        ]
        for (html, expected) in cases {
            #expect(HTMLTextExtractor.plainText(fromHTML: html) == expected, "\(html)")
        }
    }

    @Test func staysLinearOnAdversarialInput() {
        let clock = ContinuousClock()
        let entities = "<p>" + String(repeating: "a&amp;", count: 200_000) + "</p>"
        let unclosed = String(repeating: "<script><style><!--<", count: 50_000)
        let elapsed = clock.measure {
            #expect(HTMLTextExtractor.plainText(fromHTML: entities).utf8.count == 400_001)
            _ = HTMLTextExtractor.plainText(fromHTML: unclosed)
        }
        #expect(elapsed < .seconds(3), "Took \(elapsed)")
    }

    @Test func stopsJustPastTheOutputLimit() {
        let text = HTMLTextExtractor.plainText(fromHTML: String(repeating: "a", count: 1_000), maximumOutputBytes: 10)
        #expect(text.utf8.count == 11)
    }

    @Test func oversizedPlainTextIsReportedWithoutDecodingAllOfIt() {
        let data = Data(repeating: UInt8(ascii: "x"), count: 1_000_000)
        let text = PasteboardSnapshotReader.text(
            from: [NSPasteboard.PasteboardType.string.rawValue: data],
            maximumBytes: 100
        )
        #expect(text?.utf8.count == 101)
    }
}

@MainActor
private struct MechanismFixture {
    let pasteboard: NSPasteboard
    let defaults: UserDefaults
    let suite: String
    let store: ClipboardStore

    init(configuration: ClipboardStore.Configuration = .default) throws {
        suite = "ClipDeckMechanismTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "monitoring")
        pasteboard = NSPasteboard(name: .init(suite))
        store = ClipboardStore(
            pasteboard: pasteboard,
            startsMonitoring: false,
            performsLegacyCleanup: false,
            userDefaults: defaults,
            monitoringDefaultsKey: "monitoring",
            configuration: configuration,
            frontmostApplicationIdentifier: { nil }
        )
    }

    func write(data: Data, type: NSPasteboard.PasteboardType) {
        pasteboard.clearContents()
        #expect(pasteboard.setData(data, forType: type))
    }

    func close() {
        defaults.removePersistentDomain(forName: suite)
        pasteboard.releaseGlobally()
    }
}

/// A 64×48 JPEG; its uncompressed TIFF compatibility raster is ~9–12 KB, which
/// dwarfs any size jitter between two solid-color fixtures.
@MainActor
private func mechanismJPEG(red: UInt8, blue: UInt8) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8,
        samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 64 * 3, bitsPerPixel: 24
    ))
    let pixels = try #require(bitmap.bitmapData)
    for index in 0..<(64 * 48) {
        pixels[index * 3] = red
        pixels[index * 3 + 1] = 0
        pixels[index * 3 + 2] = blue
    }
    return try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
}
