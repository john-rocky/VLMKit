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

    /// Find a value on the page by trying multiple candidate strings in order
    /// — first match wins. Same case-insensitive, full-width-folded,
    /// whitespace-collapsed normalization as `DocumentQA.locate`; the tightest
    /// containing observation is preferred. Used by the schema-driven recipes
    /// (Receipt / Business Card / ID) to ground each extracted value on the
    /// photo so a row tap spotlights its location.
    ///
    /// Multiple candidates handle printed-vs-parsed variants — e.g. a receipt
    /// total of `1280` may be printed as "1,280" or "¥1,280"; a Japanese name
    /// may appear as "Yamada Taro", "Taro Yamada", or "山田 太郎".
    static func locate(
        _ candidates: [String],
        in observations: [OCRObservation],
        page: Int = 0
    ) -> CGRect? {
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let field = DocumentField(label: "", value: trimmed, page: page)
            if let box = DocumentQA.locate(fields: [field], in: observations)[0] {
                return box
            }
        }
        return nil
    }

    /// `VNRecognizeTextRequest` (accurate, language-correction on) run off the
    /// main actor. Recognition languages: the device's primary language first
    /// (for accuracy on documents in the user's locale) plus English as a
    /// universal fallback — most printed receipts/forms include English even in
    /// non-English markets (product names, error codes, brands). Vision boxes
    /// are bottom-left origin; converted to VLMKit's top-left convention here.
    static func recognize(cgImage: CGImage) async -> [OCRObservation] {
        let languages = recognitionLanguages
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages
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

    /// English + the device's primary language (when Vision recognizes it),
    /// cached once on first access. Computed lazily because building the
    /// supported-language list takes a few ms — not free, but a one-time cost.
    /// Order matters: device language first = Vision prioritizes its parser for
    /// the more likely script on screen.
    private static let recognitionLanguages: [String] = {
        let english = "en-US"
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        var languages: [String] = []
        if let device = devicePreferredLanguage(in: supported), device != english {
            languages.append(device)
        }
        if supported.contains(english) {
            languages.append(english)
        }
        // Last-resort fallback for the (unlikely) case that Vision returns an
        // empty supported list — request English anyway; Vision will accept it.
        return languages.isEmpty ? [english] : languages
    }()

    /// Map the OS-preferred language (BCP-47, e.g. "ja-JP", "zh-Hans-CN") to the
    /// closest Vision recognition language ("ja-JP", "zh-Hans"). Tries the full
    /// tag first, then progressively shorter prefixes — so "zh-Hans-CN" falls
    /// back to "zh-Hans", and "en" falls back to whatever "en-*" Vision lists
    /// (typically "en-US"). Returns nil when nothing matches.
    private static func devicePreferredLanguage(in supported: [String]) -> String? {
        guard let preferred = Locale.preferredLanguages.first else { return nil }
        let components = preferred.split(separator: "-").map(String.init)
        for length in (1...components.count).reversed() {
            let candidate = components.prefix(length).joined(separator: "-")
            if let match = supported.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return match
            }
            if let match = supported.first(where: {
                $0.lowercased().hasPrefix(candidate.lowercased() + "-")
            }) {
                return match
            }
        }
        return nil
    }
}
