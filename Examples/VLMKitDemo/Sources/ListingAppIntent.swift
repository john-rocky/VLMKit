import AppIntents
import UIKit
import VLMKit

/// Shortcuts / Siri-callable: hand it one or more product photos, get back a
/// JSON marketplace listing draft (title, description, features, condition,
/// suggested price range, tags, alt-text). Optional `intent` parameter steers
/// audience / tone (e.g. "Mercari, casual tone, Japanese buyers").
///
/// Multi-turn refinement isn't exposed through the intent itself — Shortcuts
/// users get the single best-effort draft and can wire follow-up actions
/// against the JSON (find/replace, GPT post-processing in another action,
/// etc.) themselves.
struct ExtractListingIntent: AppIntent {
    static var title: LocalizedStringResource = "Extract Listing"
    static var description = IntentDescription(
        "Generate a marketplace listing draft from one or more photos of an item.",
        categoryName: "Listings"
    )

    @Parameter(
        title: "Photos",
        description: "One or more photos of the same item, ideally from multiple angles."
    )
    var images: [IntentFile]

    @Parameter(
        title: "Seller intent",
        description: "Optional hint about marketplace, tone, or audience.",
        default: ""
    )
    var intent: String

    static var parameterSummary: some ParameterSummary {
        Summary("Build listing from \(\.$images)") {
            \.$intent
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard !images.isEmpty else {
            throw ExtractListingError.noImages
        }
        try await SharedVLM.loadIfNeeded()
        let vlmImages: [VLMImage] = images.compactMap { file in
            guard let ui = UIImage(data: file.data) else { return nil }
            return VLMImage(uiImage: ui.normalizedUp())
        }
        guard vlmImages.count == images.count else {
            throw ExtractListingError.invalidImage
        }
        let trimmedIntent = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try await Listing.generate(
            on: vlmImages,
            intent: trimmedIntent.isEmpty ? nil : trimmedIntent,
            runner: SharedVLM.runner
        )
        return .result(value: try Listing.json(data))
    }
}

enum ExtractListingError: Error, CustomLocalizedStringResourceConvertible {
    case noImages
    case invalidImage

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noImages: "At least one photo is required."
        case .invalidImage: "One of the images could not be decoded."
        }
    }
}
