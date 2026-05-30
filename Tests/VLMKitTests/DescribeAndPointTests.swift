import XCTest
@testable import VLMKit

/// Logic-only tests for `DescribeAndPoint.locate` — the deterministic phrase→range
/// linking, ordering, and capping. No model or GPU involved.
final class DescribeAndPointTests: XCTestCase {
    typealias Raw = DescribeAndPoint.DescribedObjectRaw

    func testOrdersByCaptionPositionNotArrayOrder() {
        let caption = "A dog sits on a sofa next to a lamp."
        // Supplied out of caption order on purpose — order must come from the text.
        let objects = DescribeAndPoint.locate(
            [Raw(phrase: "lamp", query: "lamp"),
             Raw(phrase: "sofa", query: "sofa"),
             Raw(phrase: "dog", query: "dog")],
            in: caption, maxObjects: 8
        )
        XCTAssertEqual(objects.map(\.phrase), ["dog", "sofa", "lamp"])
        for object in objects {
            XCTAssertEqual(String(caption[object.range]).lowercased(), object.phrase.lowercased())
        }
    }

    func testDuplicatePhrasesMapToSuccessiveOccurrences() {
        let caption = "A cat and another cat."
        let objects = DescribeAndPoint.locate(
            [Raw(phrase: "cat", query: "cat"), Raw(phrase: "cat", query: "cat")],
            in: caption, maxObjects: 8
        )
        XCTAssertEqual(objects.count, 2)
        XCTAssertLessThan(objects[0].range.lowerBound, objects[1].range.lowerBound)
        XCTAssertNotEqual(objects[0].range, objects[1].range)
    }

    func testUnfindablePhraseIsDropped() {
        let caption = "A plain red mug on a table."
        let objects = DescribeAndPoint.locate(
            [Raw(phrase: "mug", query: "mug"),
             Raw(phrase: "dragon", query: "dragon"),   // not in the caption
             Raw(phrase: "table", query: "table")],
            in: caption, maxObjects: 8
        )
        XCTAssertEqual(objects.map(\.phrase), ["mug", "table"])
    }

    func testCaseInsensitiveMatchKeepsCaptionCasing() {
        let caption = "A Dog by the Door."
        let objects = DescribeAndPoint.locate(
            [Raw(phrase: "dog", query: "dog")],
            in: caption, maxObjects: 8
        )
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(String(caption[objects[0].range]), "Dog")
    }

    func testCapsToMaxObjectsInCaptionOrder() {
        let caption = "one two three four five"
        let raw = ["five", "four", "three", "two", "one"].map { Raw(phrase: $0, query: $0) }
        let objects = DescribeAndPoint.locate(raw, in: caption, maxObjects: 3)
        XCTAssertEqual(objects.map(\.phrase), ["one", "two", "three"])
    }

    func testBlankPhraseIsSkipped() {
        let caption = "A bird on a wire."
        let objects = DescribeAndPoint.locate(
            [Raw(phrase: "   ", query: "x"), Raw(phrase: "bird", query: "bird")],
            in: caption, maxObjects: 8
        )
        XCTAssertEqual(objects.map(\.phrase), ["bird"])
    }
}
