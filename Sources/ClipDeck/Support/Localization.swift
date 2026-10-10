import Foundation

/// Resolves ClipDeck's SwiftPM resources both while testing/running from SwiftPM
/// and after the executable has been wrapped in the distributable macOS app.
enum L10n {
    static let resourceBundleName = "ClipDeck_ClipDeck"

    private static let runtimeBundle: Bundle = {
        if let bundleURL = Bundle.main.url(
            forResource: resourceBundleName,
            withExtension: "bundle"
        ), let packagedBundle = Bundle(url: bundleURL) {
            return packagedBundle
        }

        return .module
    }()

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        localizedString(
            key,
            bundle: runtimeBundle,
            locale: .current,
            arguments: arguments
        )
    }

    /// Supports deterministic localization tests without changing the user's
    /// system language or mutating global defaults.
    static func string(
        _ key: String,
        localeIdentifier: String,
        _ arguments: CVarArg...
    ) -> String {
        let normalizedIdentifier = localeIdentifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let usesSimplifiedChinese = normalizedIdentifier == "zh-hans"
            || normalizedIdentifier.hasPrefix("zh-hans-")
            || normalizedIdentifier == "zh-cn"
            || normalizedIdentifier.hasPrefix("zh-cn-")
        let resourceName = usesSimplifiedChinese ? "zh-Hans" : "en"
        guard let localizationBundle = localizationBundle(
            named: resourceName,
            in: runtimeBundle
        ) else {
            return localizedString(
                key,
                bundle: runtimeBundle,
                locale: Locale(identifier: localeIdentifier),
                arguments: arguments
            )
        }

        return localizedString(
            key,
            bundle: localizationBundle,
            locale: Locale(identifier: localeIdentifier),
            arguments: arguments
        )
    }

    /// Older SwiftPM toolchains lowercase `.lproj` folders (`zh-hans`) while
    /// newer ones keep their original casing; Bundle resource lookups are
    /// case-sensitive, so match against the localizations actually present.
    static func localizationBundle(named localization: String, in bundle: Bundle) -> Bundle? {
        let candidates = [localization] + bundle.localizations.filter {
            $0 != localization && $0.caseInsensitiveCompare(localization) == .orderedSame
        }
        for candidate in candidates {
            if let path = bundle.path(forResource: candidate, ofType: "lproj"),
               let localizedBundle = Bundle(path: path) {
                return localizedBundle
            }
        }
        return nil
    }

    private static func localizedString(
        _ key: String,
        bundle: Bundle,
        locale: Locale,
        arguments: [CVarArg]
    ) -> String {
        let format = bundle.localizedString(
            forKey: key,
            value: key,
            table: "Localizable"
        )
        guard !arguments.isEmpty else {
            return format
        }
        return String(format: format, locale: locale, arguments: arguments)
    }
}
