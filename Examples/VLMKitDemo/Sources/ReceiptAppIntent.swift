import AppIntents
import UIKit
import VLMKit

/// Shortcuts / Siri-callable: hand it a receipt image, get back a CSV row of
/// extracted fields (merchant, date, total, items, …). Runs the same on-device
/// VLM the SwiftUI app uses; sharing `SharedVLM` means one model load is reused
/// across both entry points.
///
/// Returns the CSV row (no header) as the intent's `value`, so a user-built
/// Shortcut can chain it into Append-To-File, Send-Email, Add-To-Numbers, etc.
struct ExtractReceiptIntent: AppIntent {
    static var title: LocalizedStringResource = "Extract Receipt"
    static var description = IntentDescription(
        "Read a receipt photo on-device and return its fields as a CSV row.",
        categoryName: "Receipts"
    )

    @Parameter(
        title: "Receipt photo",
        description: "An image of a printed receipt."
    )
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Extract receipt from \(\.$image)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let uiImage = UIImage(data: image.data) else {
            throw ExtractReceiptError.invalidImage
        }
        // Make sure the shared model is loaded (cheap once it has been).
        try await SharedVLM.loadIfNeeded()
        guard let vlmImage = VLMImage(uiImage: uiImage.normalizedUp()) else {
            throw ExtractReceiptError.invalidImage
        }
        let data = try await Receipt.extract(on: vlmImage, runner: SharedVLM.runner)
        return .result(value: Receipt.csvRow(data))
    }
}

enum ExtractReceiptError: Error, CustomLocalizedStringResourceConvertible {
    case invalidImage

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidImage: "The image could not be decoded as a receipt."
        }
    }
}

/// Registers every VLMKit intent with the system so Shortcuts / Siri can
/// discover them without the user opening the app first. Empty parameters here —
/// the user picks the photo when wiring the Shortcut.
struct VLMKitAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ExtractReceiptIntent(),
            phrases: [
                "Extract a receipt with \(.applicationName)",
                "Read this receipt with \(.applicationName)",
            ],
            shortTitle: "Extract Receipt",
            systemImageName: "doc.text.viewfinder"
        )
        AppShortcut(
            intent: ExtractBusinessCardIntent(),
            phrases: [
                "Extract a business card with \(.applicationName)",
                "Scan this business card with \(.applicationName)",
            ],
            shortTitle: "Extract Business Card",
            systemImageName: "person.crop.rectangle"
        )
        AppShortcut(
            intent: ExtractIDDocumentIntent(),
            phrases: [
                "Extract an ID document with \(.applicationName)",
                "Scan this ID with \(.applicationName)",
            ],
            shortTitle: "Extract ID Document",
            systemImageName: "person.text.rectangle"
        )
        AppShortcut(
            intent: ExtractListingIntent(),
            phrases: [
                "Build a listing with \(.applicationName)",
                "Write a listing with \(.applicationName)",
            ],
            shortTitle: "Build Listing",
            systemImageName: "bag.badge.plus"
        )
    }
}
