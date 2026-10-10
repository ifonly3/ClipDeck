import Foundation

/// Whitespace-separated terms that must all appear in an item, in any order:
/// "deploy staging" finds "staging … deploy" as well.
struct ClipboardSearchQuery: Equatable {
    let terms: [String]

    init(_ query: String) {
        terms = ClipboardItem.normalizedSearchText(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    var isEmpty: Bool { terms.isEmpty }

    func matches(_ item: ClipboardItem) -> Bool {
        terms.allSatisfy { Self.contains(item.searchableText, $0) }
    }

    func filter(_ items: [ClipboardItem]) -> [ClipboardItem] {
        isEmpty ? items : items.filter(matches)
    }

    /// Both sides are folded and NFC-normalized by `normalizedSearchText`, so a
    /// UTF-8 byte search finds the same matches as a Character comparison while
    /// scanning tens of kilobytes per item many times faster.
    static func contains(_ text: String, _ term: String) -> Bool {
        var text = text
        var term = term
        return term.withUTF8 { needle in
            guard needle.count > 0 else { return true }
            return text.withUTF8 { haystack in
                guard haystack.count >= needle.count,
                      let haystackStart = haystack.baseAddress,
                      let needleStart = needle.baseAddress else { return false }
                return memmem(haystackStart, haystack.count, needleStart, needle.count) != nil
            }
        }
    }
}
