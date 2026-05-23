import XCTest
@testable import VLMKit

final class JSONExtractionTests: XCTestCase {
    func testBareObject() {
        XCTAssertEqual(JSONExtraction.extractJSONString(from: #"{"a": 1}"#), #"{"a": 1}"#)
    }

    func testProseWrapped() {
        let text = "Sure! Here you go:\n{\"name\": \"x\"}\nHope that helps."
        XCTAssertEqual(JSONExtraction.extractJSONString(from: text), #"{"name": "x"}"#)
    }

    func testCodeFence() {
        let text = "```json\n{\"a\": [1,2,3]}\n```"
        XCTAssertEqual(JSONExtraction.extractJSONString(from: text), #"{"a": [1,2,3]}"#)
    }

    func testTopLevelArray() {
        let text = #"[{"x":1},{"y":2}]"#
        XCTAssertEqual(JSONExtraction.extractJSONString(from: text), text)
    }

    func testBracesInsideString() {
        let text = #"{"note": "use {curly} braces"}"#
        XCTAssertEqual(JSONExtraction.extractJSONString(from: text), text)
    }

    func testNestedObjects() {
        let text = #"prefix {"a": {"b": {"c": 1}}} suffix"#
        XCTAssertEqual(JSONExtraction.extractJSONString(from: text), #"{"a": {"b": {"c": 1}}}"#)
    }

    func testNoJSONReturnsNil() {
        XCTAssertNil(JSONExtraction.extractJSONString(from: "no json here"))
    }

    func testDecodeRoundTrip() throws {
        struct Product: Codable, Equatable { let name: String; let count: Int }
        let text = "Result: ```json\n{\"name\":\"apple\",\"count\":3}\n``` done"
        let data = try XCTUnwrap(JSONExtraction.data(from: text))
        XCTAssertEqual(try JSONDecoder().decode(Product.self, from: data), Product(name: "apple", count: 3))
    }
}
