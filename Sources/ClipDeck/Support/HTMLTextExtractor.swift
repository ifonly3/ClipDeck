import Foundation

/// A local, single-pass HTML → text fallback used for previews and search when a
/// clipboard item has no plain-text representation. The original HTML is always
/// retained byte-for-byte for pasting.
///
/// WebKit's HTML importer is deliberately avoided: it can load external
/// resources and block the main thread. Every search below only moves forward
/// and remembers failed lookups, so adversarial input (thousands of unclosed
/// `<script>` tags or entities) stays linear instead of quadratic.
enum HTMLTextExtractor {
    /// - Parameter maximumOutputBytes: Stops once the UTF-8 output exceeds this
    ///   limit. The returned text is then longer than the limit, so callers that
    ///   enforce it still reject the text instead of silently truncating it.
    static func plainText(fromHTML html: String, maximumOutputBytes: Int? = nil) -> String {
        var html = html
        return html.withUTF8 { input in
            var scanner = Scanner(input: input, maximumOutputBytes: maximumOutputBytes)
            return scanner.run()
        }
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}",
        "mdash": "—", "ndash": "–", "hellip": "…", "bull": "•", "copy": "©", "reg": "®"
    ]

    private struct Scanner {
        let input: UnsafeBufferPointer<UInt8>
        let stopCount: Int
        var output: [UInt8] = []
        // Positions after which a closing sequence is known to be absent.
        var missingTagEnd = false
        var missingCommentEnd = false
        var missingRawTextEnd: Set<String> = []

        init(input: UnsafeBufferPointer<UInt8>, maximumOutputBytes: Int?) {
            self.input = input
            self.stopCount = maximumOutputBytes.map { $0 &+ 1 } ?? Int.max
            output.reserveCapacity(min(input.count, stopCount))
        }

        mutating func run() -> String {
            var index = 0
            while index < input.count, output.count < stopCount {
                switch input[index] {
                case UInt8(ascii: "<"):
                    if let next = skipMarkup(at: index) {
                        index = next
                    } else {
                        output.append(UInt8(ascii: "<"))
                        index += 1
                    }
                case UInt8(ascii: "&"):
                    if let (decoded, next) = decodeEntity(at: index) {
                        output.append(contentsOf: decoded.utf8)
                        index = next
                    } else {
                        output.append(UInt8(ascii: "&"))
                        index += 1
                    }
                default:
                    output.append(input[index])
                    index += 1
                }
            }
            return String(decoding: output, as: UTF8.self)
        }

        /// Returns the index after a comment, element, or tag, or nil when `<`
        /// must stay literal (for example `a < b` without a closing `>`).
        private mutating func skipMarkup(at start: Int) -> Int? {
            if hasPrefix("<!--", at: start), let end = find("-->", from: start + 4, missing: &missingCommentEnd) {
                return end + 3
            }
            let nameStart = start + 1
            guard nameStart < input.count, input[nameStart] != UInt8(ascii: ">") else { return nil }
            guard let tagEnd = find(">", from: nameStart, missing: &missingTagEnd) else { return nil }

            let isClosing = input[nameStart] == UInt8(ascii: "/")
            let name = tagName(from: isClosing ? nameStart + 1 : nameStart, limit: tagEnd)
            if isClosing {
                if Self.lineBreakingClosingTags.contains(name) { output.append(UInt8(ascii: "\n")) }
                return tagEnd + 1
            }
            if name == "br" {
                output.append(UInt8(ascii: "\n"))
                return tagEnd + 1
            }
            if name == "script" || name == "style", let elementEnd = rawTextElementEnd(named: name, after: tagEnd + 1) {
                return elementEnd
            }
            return tagEnd + 1
        }

        private static let lineBreakingClosingTags: Set<String> = [
            "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"
        ]

        /// Lowercased ASCII tag name; empty when the tag does not start with one.
        private func tagName(from start: Int, limit: Int) -> String {
            var bytes: [UInt8] = []
            var index = start
            while index < limit, bytes.count < 16 {
                let byte = input[index]
                let isLetter = (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
                let isDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
                guard isLetter || (isDigit && !bytes.isEmpty) else { break }
                bytes.append(isLetter ? byte | 0x20 : byte)
                index += 1
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        /// Finds `</name\s*>` case-insensitively and returns the index after it.
        private mutating func rawTextElementEnd(named name: String, after start: Int) -> Int? {
            guard !missingRawTextEnd.contains(name) else { return nil }
            let closing = Array("</\(name)".utf8)
            var index = start
            while index + closing.count <= input.count {
                if matchesCaseInsensitive(closing, at: index) {
                    var end = index + closing.count
                    while end < input.count, isWhitespace(input[end]) { end += 1 }
                    if end < input.count, input[end] == UInt8(ascii: ">") { return end + 1 }
                }
                index += 1
            }
            missingRawTextEnd.insert(name)
            return nil
        }

        private func decodeEntity(at start: Int) -> (String, Int)? {
            var index = start + 1
            guard index < input.count else { return nil }
            if input[index] == UInt8(ascii: "#") {
                index += 1
                let isHex = index < input.count && (input[index] | 0x20) == UInt8(ascii: "x")
                if isHex { index += 1 }
                let digitsStart = index
                var value: UInt32 = 0
                var overflowed = false
                while index < input.count, let digit = digitValue(input[index], hex: isHex) {
                    let (multiplied, overflow1) = value.multipliedReportingOverflow(by: isHex ? 16 : 10)
                    let (added, overflow2) = multiplied.addingReportingOverflow(digit)
                    overflowed = overflowed || overflow1 || overflow2
                    value = added
                    index += 1
                }
                guard index > digitsStart, index < input.count, input[index] == UInt8(ascii: ";"),
                      !overflowed, let scalar = Unicode.Scalar(value) else { return nil }
                return (String(Character(scalar)), index + 1)
            }
            let nameStart = index
            while index < input.count, index - nameStart <= 8 {
                let byte = input[index] | 0x20
                guard byte >= UInt8(ascii: "a"), byte <= UInt8(ascii: "z") else { break }
                index += 1
            }
            guard index > nameStart, index < input.count, input[index] == UInt8(ascii: ";") else { return nil }
            let name = String(decoding: UnsafeBufferPointer(rebasing: input[nameStart..<index]), as: UTF8.self)
            guard let decoded = HTMLTextExtractor.namedEntities[name] else { return nil }
            return (decoded, index + 1)
        }

        private func digitValue(_ byte: UInt8, hex: Bool) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f") where hex: return UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F") where hex: return UInt32(byte - UInt8(ascii: "A") + 10)
            default: return nil
            }
        }

        /// Forward search that records a miss: once a sequence is absent after
        /// some position, it is absent after every later position too.
        private func find(_ needle: StaticString, from start: Int, missing: inout Bool) -> Int? {
            guard !missing else { return nil }
            let bytes = UnsafeBufferPointer(start: needle.utf8Start, count: needle.utf8CodeUnitCount)
            var index = start
            while index + bytes.count <= input.count {
                if input[index] == bytes[0], bytes.indices.allSatisfy({ input[index + $0] == bytes[$0] }) {
                    return index
                }
                index += 1
            }
            missing = true
            return nil
        }

        private func hasPrefix(_ prefix: StaticString, at start: Int) -> Bool {
            let bytes = UnsafeBufferPointer(start: prefix.utf8Start, count: prefix.utf8CodeUnitCount)
            guard start + bytes.count <= input.count else { return false }
            return bytes.indices.allSatisfy { input[start + $0] == bytes[$0] }
        }

        private func matchesCaseInsensitive(_ bytes: [UInt8], at start: Int) -> Bool {
            bytes.indices.allSatisfy { offset in
                let byte = input[start + offset]
                let expected = bytes[offset]
                return byte == expected || (expected >= UInt8(ascii: "a") && byte | 0x20 == expected)
            }
        }

        private func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
        }
    }
}
