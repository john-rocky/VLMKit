import CoreGraphics
import Foundation
import Vision
import VLMKit

/// Vision-based on-device OCR for Document QA — recognizes every line of text on
/// the document and (via `DocumentQA.locate`) boxes each extracted field's value
/// on the photo.
///
/// VLMKit's core recipe stays OCR-engine-agnostic: it operates on generic
/// `OCRObservation` pairs. This provider is the Vision plug-in for the app — no
/// model download, no extra dependency, ~0.3–1 s on a typical doc photo.
/// Stateless, so it lives as an enum with static methods.
enum OCRProvider {
    /// Recognize text on the image, then locate each field's value. Convenience
    /// over `recognize` + `DocumentQA.locate`. Missing fields are absent from the
    /// result; the caller decides how to render those rows.
    static func ground(cgImage: CGImage, fields: [DocumentField]) async -> [Int: CGRect] {
        let observations = await recognize(cgImage: cgImage)
        return DocumentQA.locate(fields: fields, in: observations)
    }

    /// `VNRecognizeTextRequest` (accurate, language-correction on, EN + JA) run
    /// off the main actor. Vision boxes are bottom-left origin; convert here to
    /// VLMKit's top-left origin so callers can use the result as-is.
    static func recognize(cgImage: CGImage) async -> [OCRObservation] {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US", "ja-JP"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            guard let results = request.results else { return [] }
            return results.compactMap { observation -> OCRObservation? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let bb = observation.boundingBox  // bottom-left origin, normalized
                let topLeftBox = CGRect(
                    x: bb.minX,
                    y: 1 - bb.maxY,
                    width: bb.width,
                    height: bb.height
                )
                return OCRObservation(text: text, box: topLeftBox)
            }
        }.value
    }
}
