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
}
