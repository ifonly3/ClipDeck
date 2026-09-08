import Foundation
import Testing
@testable import ClipDeck

@Test func versionLabelsComeFromBundleMetadata() {
    let version = AppVersion(infoDictionary: [
        "CFBundleShortVersionString": "2.7.3",
        "CFBundleVersion": "42"
    ])
    #expect(version.version == "2.7.3")
    #expect(version.build == "42")
    #expect(version.shortLabel == "v2.7.3")
    #expect(version.displayText.contains("2.7.3"))
    #expect(version.displayText.contains("42"))
}

@Test func missingBundleVersionDoesNotPretendToBeARelease() {
    let missing = AppVersion(infoDictionary: [:])
    let invalid = AppVersion(infoDictionary: ["CFBundleShortVersionString": "  "])
    #expect(missing.version == nil)
    #expect(missing.shortLabel == L10n.string("开发版本"))
    #expect(invalid.displayText == missing.displayText)
    let withoutBuild = AppVersion(infoDictionary: ["CFBundleShortVersionString": " 2.0.0\n"])
    #expect(withoutBuild.version == "2.0.0")
    #expect(withoutBuild.build == nil)
    #expect(withoutBuild.displayText == L10n.string("版本 %@", "2.0.0"))
}

@Test func releaseTemplateHasAVisibleVersionAndBuild() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("script/ClipDeck-Info.plist"))
    let dictionary = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let version = AppVersion(infoDictionary: dictionary)
    #expect(version.version?.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil)
    #expect(version.build.flatMap(Int.init).map { $0 > 0 } == true)
}
