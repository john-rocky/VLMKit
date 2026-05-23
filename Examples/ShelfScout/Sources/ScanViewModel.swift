import SwiftUI
import VLMKit

/// Drives the demo: loads the model once, then runs α1 ShelfInventory on a
/// captured image and publishes progress/results for the UI.
@MainActor
final class ScanViewModel: ObservableObject {
    enum Phase {
        case downloading(Double)
        case ready
        case scanning(done: Int, total: Int)
        case result(ShelfReport)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .downloading(0)
    @Published private(set) var capturedImage: UIImage?

    // Default preset (~3 GB). Swap for `.smolVLM2` to test with a smaller, faster download.
    private let backend = MLXSwiftBackend(profile: .qwen3VL4B)
    private lazy var runner = VLMRunner(backend: backend)
    private var didStartLoading = false

    var modelName: String { backend.profile.displayName }

    /// Download (first launch) and load the model. Safe to call repeatedly.
    func loadModelIfNeeded() async {
        guard !didStartLoading else { return }
        didStartLoading = true
        do {
            try await backend.load { [weak self] fraction in
                Task { @MainActor in self?.phase = .downloading(fraction) }
            }
            phase = .ready
        } catch {
            phase = .failed("Model load failed: \(error)")
        }
    }

    /// Run the shelf-inventory fan-out over a `detail × detail` grid.
    func scan(_ image: UIImage, detail: Int) async {
        guard let vlmImage = VLMImage(uiImage: image.normalizedUp()) else {
            phase = .failed("Could not read the captured image.")
            return
        }
        capturedImage = image
        phase = .scanning(done: 0, total: detail * detail)
        do {
            let report = try await ShelfInventory.run(
                on: vlmImage, runner: runner, rows: detail, columns: detail
            ) { [weak self] done, total in
                Task { @MainActor in self?.phase = .scanning(done: done, total: total) }
            }
            phase = .result(report)
        } catch {
            phase = .failed("Scan failed: \(error)")
        }
    }
}

private extension UIImage {
    /// Bake EXIF orientation into pixels — `VLMImage` reads the raw `CGImage`,
    /// so a camera photo must be uprighted before tiling or the VLM sees it rotated.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
