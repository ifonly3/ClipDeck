import Foundation
import Testing
@testable import ClipDeck

@Test
func criticalInterfaceStringsAreAvailableInEnglishAndSimplifiedChinese() {
    #expect(
        L10n.string("剪贴板历史", localeIdentifier: "en")
            == "Clipboard History"
    )
    #expect(
        L10n.string("剪贴板历史", localeIdentifier: "zh-Hans")
            == "剪贴板历史"
    )
    #expect(
        L10n.string("设置", localeIdentifier: "en")
            == "Settings"
    )
    #expect(
        L10n.string("设置", localeIdentifier: "zh-Hans")
            == "设置"
    )
    #expect(
        L10n.string("剪贴板历史", localeIdentifier: "zh-CN")
            == "剪贴板历史"
    )
    #expect(
        L10n.string("剪贴板历史", localeIdentifier: "zh_Hans_CN")
            == "剪贴板历史"
    )
    #expect(
        L10n.string("剪贴板历史", localeIdentifier: "zh-Hant")
            == "Clipboard History"
    )
    #expect(
        L10n.string("剪贴板历史", localeIdentifier: "zh-TW")
            == "Clipboard History"
    )
}

@Test
func localizedFormatsCoverCountsErrorsAndAccessibilityText() {
    #expect(
        L10n.string("清空 %lld 条历史", localeIdentifier: "en", Int64(4))
            == "Clear 4 items"
    )
    #expect(
        L10n.string("清空 %lld 条历史", localeIdentifier: "zh-Hans", Int64(4))
            == "清空 4 条历史"
    )
    #expect(
        L10n.string(
            "无法启用全局快捷键（错误码 %d）。请检查快捷键冲突后重试。",
            localeIdentifier: "en",
            Int32(-987)
        ).contains("error -987")
    )
    #expect(
        L10n.string(
            "操作：单击选择，上下方向键切换，回车复制，删除键删除，Escape 关闭窗口",
            localeIdentifier: "en"
        ).hasPrefix("Actions:")
    )
}

@Test
func englishAndChineseTablesContainTheSameKeys() throws {
    let english = try localizedTable(named: "en")
    let chinese = try localizedTable(named: "zh-Hans")

    #expect(!english.isEmpty)
    #expect(Set(english.keys) == Set(chinese.keys))
    #expect(english.values.allSatisfy { !$0.isEmpty })
    #expect(chinese.values.allSatisfy { !$0.isEmpty })
}

@Test
func sourceLocalizationKeysExactlyMatchBothTables() throws {
    let sourceKeys = try localizationKeysUsedInSources()
    let englishKeys = Set(try localizedTable(named: "en").keys)
    let chineseKeys = Set(try localizedTable(named: "zh-Hans").keys)

    #expect(!sourceKeys.isEmpty)
    #expect(
        sourceKeys == englishKeys,
        "English table mismatch. Missing: \(sourceKeys.subtracting(englishKeys).sorted()); unused: \(englishKeys.subtracting(sourceKeys).sorted())"
    )
    #expect(
        sourceKeys == chineseKeys,
        "Simplified Chinese table mismatch. Missing: \(sourceKeys.subtracting(chineseKeys).sorted()); unused: \(chineseKeys.subtracting(sourceKeys).sorted())"
    )
}

@Test
func everyLocalizedFormatPreservesTheSourcePlaceholderSignature() throws {
    let english = try localizedTable(named: "en")
    let chinese = try localizedTable(named: "zh-Hans")

    for key in english.keys.sorted() {
        let sourceSignature = try printfPlaceholderSignature(in: key)
        let englishValue = try #require(english[key])
        let chineseValue = try #require(chinese[key])

        #expect(
            try printfPlaceholderSignature(in: englishValue) == sourceSignature,
            "English placeholders do not match the source key: \(key)"
        )
        #expect(
            try printfPlaceholderSignature(in: chineseValue) == sourceSignature,
            "Simplified Chinese placeholders do not match the source key: \(key)"
        )
    }
}

private func localizedTable(named localization: String) throws -> [String: String] {
    let resourceLocalization = localization == "zh-Hans" ? "zh-hans" : localization
    let localizationPath = try #require(
        Bundle.module.path(forResource: resourceLocalization, ofType: "lproj")
    )
    let tableURL = URL(fileURLWithPath: localizationPath)
        .appendingPathComponent("Localizable.strings")
    let dictionary = try #require(
        NSDictionary(contentsOf: tableURL) as? [String: String]
    )
    return dictionary
}

private func localizationKeysUsedInSources() throws -> Set<String> {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourcesDirectory = projectRoot
        .appendingPathComponent("Sources", isDirectory: true)
        .appendingPathComponent("ClipDeck", isDirectory: true)
    let sourceFiles = try swiftSourceFiles(in: sourcesDirectory)
    let keyPattern = try NSRegularExpression(
        pattern: #"L10n\.string\(\s*"((?:\\.|[^"\\])*)""#
    )
    var keys = Set<String>()

    for sourceFile in sourceFiles {
        let source = try String(contentsOf: sourceFile, encoding: .utf8)
        let sourceRange = NSRange(source.startIndex..., in: source)
        for match in keyPattern.matches(in: source, range: sourceRange) {
            guard let keyRange = Range(match.range(at: 1), in: source) else {
                continue
            }
            keys.insert(String(source[keyRange]))
        }
    }

    return keys
}

private func swiftSourceFiles(in directory: URL) throws -> [URL] {
    let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        )
    )
    var sourceFiles: [URL] = []

    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
        if values.isRegularFile == true {
            sourceFiles.append(fileURL)
        }
    }

    return sourceFiles.sorted { $0.path < $1.path }
}

private func printfPlaceholderSignature(in format: String) throws -> [String] {
    let placeholderPattern = try NSRegularExpression(
        pattern: #"%(?:%|(?:\d+\$)?[-+#0 ']*(?:(?:\d+|\*(?:\d+\$)?))?(?:\.(?:\d+|\*(?:\d+\$)?))?(?:hh|h|ll|l|q|L|z|t|j)?[@diuoxXfFeEgGaAcCsSpn])"#
    )
    let formatRange = NSRange(format.startIndex..., in: format)
    let matches = placeholderPattern.matches(in: format, range: formatRange)
    var placeholders: [String] = []

    for match in matches {
        guard let range = Range(match.range, in: format) else {
            continue
        }
        let placeholder = String(format[range])
        if placeholder != "%%" {
            placeholders.append(placeholder)
        }
    }

    return placeholders
}
