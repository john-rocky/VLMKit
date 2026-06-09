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
