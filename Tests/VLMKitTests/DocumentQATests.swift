import CoreGraphics
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

    // MARK: - locate (OCR-grounded field boxing)

    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    func testLocateFindsExactSubstring() {
        let fields = [DocumentField(label: "Model", value: "XJ-100A")]
        let valueBox = box(0.4, 0.1, 0.2, 0.05)
        let observations = [
            OCRObservation(text: "Model Number", box: box(0.1, 0.1, 0.2, 0.05)),
            OCRObservation(text: "XJ-100A", box: valueBox),
        ]
        XCTAssertEqual(DocumentQA.locate(fields: fields, in: observations)[0], valueBox)
    }

    /// When multiple observations contain the value, the tightest (shortest) one
    /// wins — the narrow box around the value, not a wide line that mentions it.
    func testLocatePicksTightestObservation() {
        let fields = [DocumentField(label: "Model", value: "X-100")]
        let tight = box(0.4, 0.1, 0.1, 0.05)
        let wide = box(0.0, 0.1, 0.9, 0.05)
        let observations = [
            OCRObservation(text: "the model number is X-100 yes", box: wide),
            OCRObservation(text: "X-100", box: tight),
        ]
        XCTAssertEqual(DocumentQA.locate(fields: fields, in: observations)[0], tight)
    }

    func testLocateIsCaseInsensitive() {
        let fields = [DocumentField(label: "Code", value: "ABC")]
        let observations = [OCRObservation(text: "abc", box: box(0, 0, 1, 1))]
        XCTAssertNotNil(DocumentQA.locate(fields: fields, in: observations)[0])
    }

    /// Full-width Latin/digits/punctuation in OCR output match the half-width
    /// field value the VLM extracted (common on Japanese signage/forms).
    func testLocateFoldsFullwidthToHalfwidth() {
        let fields = [DocumentField(label: "Code", value: "XJ-100")]
        let observations = [OCRObservation(text: "ＸＪ-１００", box: box(0, 0, 1, 1))]
        XCTAssertNotNil(DocumentQA.locate(fields: fields, in: observations)[0])
    }

    func testLocateMissingFieldIsAbsent() {
        let fields = [
            DocumentField(label: "A", value: "found"),
            DocumentField(label: "B", value: "not present"),
        ]
        let observations = [OCRObservation(text: "found here", box: box(0, 0, 1, 1))]
        let result = DocumentQA.locate(fields: fields, in: observations)
        XCTAssertNotNil(result[0])
        XCTAssertNil(result[1])
    }

    func testLocateIndexesAreStable() {
        let fields = [
            DocumentField(label: "A", value: "alpha"),
            DocumentField(label: "B", value: "beta"),
            DocumentField(label: "C", value: "gamma"),
        ]
        let alphaBox = box(0.1, 0.1, 0.1, 0.05)
        let gammaBox = box(0.3, 0.3, 0.1, 0.05)
        let observations = [
            OCRObservation(text: "alpha", box: alphaBox),
            // B (beta) has no observation — gap in the result, not a shift.
            OCRObservation(text: "gamma", box: gammaBox),
        ]
        let result = DocumentQA.locate(fields: fields, in: observations)
        XCTAssertEqual(result[0], alphaBox)
        XCTAssertNil(result[1])
        XCTAssertEqual(result[2], gammaBox)
    }

    func testNormalizeCollapsesWhitespace() {
        XCTAssertEqual(DocumentQA.normalize("  Frame   No.\nXJ-100\t"), "frame no. xj-100")
    }

    // MARK: - partialAnswer (streaming JSON extraction)

    func testPartialAnswerNilBeforeKey() {
        XCTAssertNil(DocumentQA.partialAnswer(in: ""))
        XCTAssertNil(DocumentQA.partialAnswer(in: "{\"ans"))
    }

    func testPartialAnswerNilBeforeOpeningQuote() {
        XCTAssertNil(DocumentQA.partialAnswer(in: #"{"answer""#))
        XCTAssertNil(DocumentQA.partialAnswer(in: #"{"answer":"#))
        XCTAssertNil(DocumentQA.partialAnswer(in: #"{"answer": "#))
    }

    /// The opening quote arrived but no chars yet — return an empty string so the
    /// caller can render "started, no characters yet" rather than "not started".
    func testPartialAnswerEmptyRightAfterOpeningQuote() {
        XCTAssertEqual(DocumentQA.partialAnswer(in: #"{"answer":""#), "")
    }

    func testPartialAnswerGrowingValue() {
        XCTAssertEqual(DocumentQA.partialAnswer(in: #"{"answer":"X"#), "X")
        XCTAssertEqual(DocumentQA.partialAnswer(in: #"{"answer":"XJ"#), "XJ")
        XCTAssertEqual(DocumentQA.partialAnswer(in: #"{"answer":"XJ-100"#), "XJ-100")
    }

    func testPartialAnswerClosedReturnsFullValue() {
        XCTAssertEqual(DocumentQA.partialAnswer(in: #"{"answer":"XJ-100A""#), "XJ-100A")
    }

    func testPartialAnswerHandlesEscapedQuote() {
        XCTAssertEqual(
            DocumentQA.partialAnswer(in: #"{"answer":"He said \"hi\""#),
            "He said \"hi\""
        )
    }

    func testPartialAnswerHandlesNewlineEscape() {
        XCTAssertEqual(DocumentQA.partialAnswer(in: #"{"answer":"a\nb"#), "a\nb")
    }

    /// A trailing `\` (escape arrived, escapee hasn't yet) must hold off — don't
    /// emit the backslash, wait for the next chunk that brings the escapee.
    func testPartialAnswerHoldsPendingEscape() {
        XCTAssertEqual(DocumentQA.partialAnswer(in: #"{"answer":"a\"#), "a")
    }

    func testPartialAnswerStopsAtFirstClosingQuoteIgnoringEvidence() {
        let text = #"{"answer":"XJ-100A","evidence":"Frame No. XJ-100A"}"#
        XCTAssertEqual(DocumentQA.partialAnswer(in: text), "XJ-100A")
    }
}
