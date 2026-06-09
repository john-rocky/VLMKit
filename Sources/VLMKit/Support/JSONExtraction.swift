import Foundation

/// Pulls a JSON value out of a VLM's free-form text response.
///
/// Models often wrap JSON in prose ("Here is the result:") or markdown code
/// fences. There is no schema-constrained decoding in the MLX Swift backend, so
/// VLMKit recovers the JSON from the text and decodes it on the Swift side.
enum JSONExtraction {
    /// UTF-8 data for the first balanced JSON object/array found in `text`.
    static func data(from text: String) -> Data? {
        extractJSONString(from: text)?.data(using: .utf8)
    }

    /// The first balanced JSON object/array found in `text`, or `nil`.
    static func extractJSONString(from text: String) -> String? {
        firstBalancedJSON(in: strippingCodeFence(text))
    }

    /// If `text` contains a ``` fenced block, return its inner content
    /// (dropping an optional language tag like ```json); otherwise return `text`.
    private static func strippingCodeFence(_ text: String) -> String {
        guard let open = text.range(of: "```") else { return text }
        let afterOpen = text[open.upperBound...]
        // Drop the rest of the fence line (the optional language tag).
        let body: Substring
        if let newline = afterOpen.firstIndex(of: "\n") {
            body = afterOpen[afterOpen.index(after: newline)...]
        } else {
            body = afterOpen
        }
        guard let close = body.range(of: "```") else { return String(body) }
        return String(body[..<close.lowerBound])
    }

    /// Scan for the first balanced `{...}` or `[...]`, respecting string literals
    /// and escapes so braces inside strings are not counted.
    private static func firstBalancedJSON(in text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let open = chars[start]
        let close: Character = open == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 { return String(chars[start...i]) }
            }
        }
        return nil
    }

    /// All `"key": "value"` string entries (for the given keys), in document order.
    /// Tolerant of broken JSON structure — missing braces, truncation, trailing junk —
    /// so a recipe can recover a flat key/value list when a quantized model emits
    /// malformed JSON that strict decoding rejects (e.g. dropping the `{` on array
    /// elements). Values are JSON-unescaped.
    static func orderedStringEntries(keys: Set<String>, in text: String) -> [(key: String, value: String)] {
        guard !keys.isEmpty else { return [] }
        let keyAlternation = keys
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = "\"(\(keyAlternation))\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (key: ns.substring(with: match.range(at: 1)),
             value: unescapeJSONString(ns.substring(with: match.range(at: 2))))
        }
    }

    /// Best-effort structural repair of the most common quantized-model JSON breakage:
    /// the opening `{` dropped on array elements (`[{...}, "k":v}, "k":v}]`) and/or a
    /// truncated tail. Walks the first JSON span tracking array/object context, inserts
    /// `{` whenever a key appears directly inside an array (an element that lost its
    /// brace), drops any truncated tail past the last close, and balances unclosed
    /// braces. Returns nil if there's no JSON. Meant only as a fallback after strict
    /// decoding fails — valid JSON has no keys at array level, so it is returned intact.
    static func repaired(from text: String) -> String? {
        let chars = Array(strippingCodeFence(text))
        guard let start = chars.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = chars.lastIndex(where: { $0 == "}" || $0 == "]" }),
              end >= start else { return nil }

        var out: [Character] = []
        var stack: [Character] = []          // "{" object · "[" array · "i" inserted object
        var inString = false
        var escaped = false
        var i = start
        while i <= end {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                // A key (string followed by ':') directly inside an array means an
                // object element lost its opening brace — put it back.
                if stack.last == "[", stringIsKey(chars, from: i, upTo: end) {
                    out.append("{")
                    stack.append("i")
                }
                out.append(c); inString = true
            case "{": out.append(c); stack.append("{")
            case "[": out.append(c); stack.append("[")
            case "}":
                out.append(c)
                if stack.last == "{" || stack.last == "i" { stack.removeLast() }
            case "]":
                if stack.last == "i" { out.append("}"); stack.removeLast() }
                out.append(c)
                if stack.last == "[" { stack.removeLast() }
            default:
                // An inserted object closes on `}` (the model keeps the closing brace
                // even when it drops the opening one); commas inside it are normal.
                out.append(c)
            }
            i += 1
        }
        while let top = stack.popLast() { out.append(top == "[" ? "]" : "}") }
        return String(out)
    }

    /// Whether the string literal starting at `quoteIndex` is a JSON key — i.e. its
    /// closing quote is followed (after whitespace) by `:`.
    private static func stringIsKey(_ chars: [Character], from quoteIndex: Int, upTo end: Int) -> Bool {
        var j = quoteIndex + 1
        var escaped = false
        while j <= end {
            let c = chars[j]
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { break }
            j += 1
        }
        j += 1
        while j <= end, chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r" { j += 1 }
        return j <= end && chars[j] == ":"
    }

    /// Decode JSON string escapes (`\"`, `\\`, `\n`, `\uXXXX`, …) in an already-extracted
    /// string body. Best-effort: returns the input unchanged if it has no escapes or
    /// can't be parsed.
    private static func unescapeJSONString(_ body: String) -> String {
        guard body.contains("\\") else { return body }
        guard let data = "\"\(body)\"".data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String
        else { return body }
        return decoded
    }
}
