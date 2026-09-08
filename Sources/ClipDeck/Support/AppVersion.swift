import Foundation

/// The installed bundle is the single source of truth for visible version labels.
struct AppVersion {
    static let current = AppVersion(infoDictionary: Bundle.main.infoDictionary ?? [:])

    let version: String?
    let build: String?

    init(infoDictionary: [String: Any]) {
        func value(_ key: String) -> String? {
            guard let raw = infoDictionary[key] as? String else { return nil }
            let result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")
    }

    var shortLabel: String {
        version.map { "v\($0)" } ?? L10n.string("开发版本")
    }

    var displayText: String {
        guard let version else { return L10n.string("开发版本") }
        guard let build else { return L10n.string("版本 %@", version) }
        return L10n.string("版本 %@（构建 %@）", version, build)
    }
}
