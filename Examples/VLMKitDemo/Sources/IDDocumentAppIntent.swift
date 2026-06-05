import AppIntents
import UIKit
import VLMKit

/// Shortcuts / Siri-callable: hand it an ID-document photo, get back a JSON
/// string of the extracted KYC fields. JSON keeps every schema key (null for
/// missing) so downstream Shortcuts can key into the object without an
/// exists-check. Same shared `SharedVLM` backend as the SwiftUI app so model
/// weights are loaded once per process.
///
/// On-device only — the privacy story is the entire reason this recipe exists.
/// Callers building automations against this should keep that promise (don't
/// pipe the JSON to a cloud action if the user didn't ask for it).
struct ExtractIDDocumentIntent: AppIntent {
    static var title: LocalizedStringResource = "Extract ID Document"
    static var description = IntentDescription(
        "Read an ID document photo on-device and return its fields as JSON.",
        categoryName: "ID"
    )

    @Parameter(
        title: "ID photo",
        description: "An image of a passport, driver's license, national ID, or similar."
    )
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Extract ID document from \(\.$image)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let uiImage = UIImage(data: image.data) else {
            throw ExtractIDDocumentError.invalidImage
        }
        try await SharedVLM.loadIfNeeded()
        guard let vlmImage = VLMImage(uiImage: uiImage.normalizedUp()) else {
            throw ExtractIDDocumentError.invalidImage
        }
        let data = try await IDDocument.extract(on: vlmImage, runner: SharedVLM.runner)
        return .result(value: try IDDocument.json(data))
    }
}

enum ExtractIDDocumentError: Error, CustomLocalizedStringResourceConvertible {
    case invalidImage

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidImage: "The image could not be decoded as an ID document."
        }
    }
}
