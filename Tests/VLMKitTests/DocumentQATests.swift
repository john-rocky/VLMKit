import XCTest
@testable import VLMKit

/// Logic-only tests for `DocumentQA` cleaners — the deterministic shaping the
/// recipe applies between the raw model output and the public types. No model or
/// GPU involved.
final class DocumentQATests: XCTestCase {
    func testCleanDropsBlankLabelOrValue() {
        let raw = [
            DocumentField(label: "Model", value: "X-100"),
            DocumentField(label: "", value: "no-label"),
            DocumentField(label: "Serial", value: ""),
            DocumentField(label: "  ", value: "  "),
            DocumentField(label: "Date", value: "2026-06-01"),
        ]
        XCTAssertEqual(
            DocumentQA.clean(raw, maxFields: 16),
            [
                DocumentField(label: "Model", value: "X-100"),
                DocumentField(label: "Date", value: "2026-06-01"),
            ]
        )
    }

    func testCleanTrimsWhitespace() {
        let raw = [DocumentField(label: "  Model  ", value: " X-100\n")]
        XCTAssertEqual(
            DocumentQA.clean(raw, maxFields: 16),
            [DocumentField(label: "Model", value: "X-100")]
        )
    }

    /// Order must be preserved (the model lists fields in reading order, which
    /// matches the page) and the result must be capped to `maxFields`.
    func testCleanPreservesOrderAndCaps() {
        let raw = (1...20).map { DocumentField(label: "f\($0)", value: "v\($0)") }
        let cleaned = DocumentQA.clean(raw, maxFields: 5)
        XCTAssertEqual(cleaned.map(\.label), ["f1", "f2", "f3", "f4", "f5"])
    }

    func testCleanAnswerTrimsAndDropsEmptyEvidence() {
        let a = DocumentQA.cleanAnswer(DocumentQA.AnswerRaw(answer: "  XJ-100  ", evidence: "   "))
        XCTAssertEqual(a.answer, "XJ-100")
        XCTAssertNil(a.evidence)
    }

    func testCleanAnswerKeepsNonEmptyEvidence() {
        let a = DocumentQA.cleanAnswer(DocumentQA.AnswerRaw(answer: "XJ-100", evidence: " Model: XJ-100 "))
        XCTAssertEqual(a.evidence, "Model: XJ-100")
    }

    func testCleanAnswerEvidenceMayBeNil() {
        let a = DocumentQA.cleanAnswer(DocumentQA.AnswerRaw(answer: "Not stated", evidence: nil))
        XCTAssertEqual(a.answer, "Not stated")
        XCTAssertNil(a.evidence)
    }
}
