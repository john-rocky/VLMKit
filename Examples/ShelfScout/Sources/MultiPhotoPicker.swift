import PhotosUI
import SwiftUI
import UIKit

/// SwiftUI wrapper around `PHPickerViewController` for multi-photo selection.
/// Used by the Listing demo where the seller picks 3–5 angles of the same
/// item from their photo library. `selectionLimit: 0` would mean unlimited;
/// we cap at a sensible default so the VLM input doesn't balloon.
struct MultiPhotoPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onPick: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = selectionLimit
        config.filter = .images
        // Order matters — sellers usually take the hero shot first; preserve it.
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: MultiPhotoPicker
        init(_ parent: MultiPhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Load each item provider asynchronously, preserving the order the
            // user picked them in (PHPickerResult comes back in selection order
            // because we set .ordered above).
            Task {
                let images = await Self.loadImages(from: results)
                await MainActor.run {
                    parent.onPick(images)
                    parent.dismiss()
                }
            }
        }

        private static func loadImages(from results: [PHPickerResult]) async -> [UIImage] {
            await withTaskGroup(of: (Int, UIImage?).self, returning: [UIImage].self) { group in
                for (index, result) in results.enumerated() {
                    group.addTask {
                        let image = await Self.loadImage(from: result.itemProvider)
                        return (index, image)
                    }
                }
                var byIndex: [Int: UIImage] = [:]
                for await (i, maybe) in group {
                    if let image = maybe { byIndex[i] = image }
                }
                return (0..<results.count).compactMap { byIndex[$0] }
            }
        }

        private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
            guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
            return await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    continuation.resume(returning: object as? UIImage)
                }
            }
        }
    }
}
