import AppIntents
import UIKit
import VLMKit

/// Shortcuts / Siri-callable: hand it a business-card photo, get back a
/// vCard 3.0 string of the extracted fields. The vCard can be chained into
/// Save Contact, Send Email, or written to a `.vcf` file in any user-built
/// Shortcut. Same shared `SharedVLM` backend as the SwiftUI app, so one model
/// load covers both entry points.
struct ExtractBusinessCardIntent: AppIntent {
    static var title: LocalizedStringResource = "Extract Business Card"
    static var description = IntentDescription(
        "Read a business-card photo on-device and return its fields as a vCard.",
        categoryName: "Contacts"
    )

    @Parameter(
        title: "Business-card photo",
        description: "An image of a printed business card."
    )
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Extract business card from \(\.$image)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let uiImage = UIImage(data: image.data) else {
            throw ExtractBusinessCardError.invalidImage
        }
        try await SharedVLM.loadIfNeeded()
        guard let vlmImage = VLMImage(uiImage: uiImage.normalizedUp()) else {
            throw ExtractBusinessCardError.invalidImage
        }
        let data = try await BusinessCard.extract(on: vlmImage, runner: SharedVLM.runner)
        return .result(value: BusinessCard.vCard(data))
    }
}

enum ExtractBusinessCardError: Error, CustomLocalizedStringResourceConvertible {
    case invalidImage

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidImage: "The image could not be decoded as a business card."
        }
    }
}
