import SwiftUI
import VLMKit

/// Drives the multi-demo shell: loads the model once (shared across demos), runs the
/// selected demo on a captured image, and publishes progress/results. Switching
/// demos reuses the loaded model — no reload of the ~3 GB weights.
@MainActor
final class DemoViewModel: ObservableObject {
    enum Phase {
        case preparing
        case downloading(Double)
        case ready
        /// `total == 0` means the count isn't known yet (e.g. Vision hasn't run) —
        /// render an indeterminate spinner until the first progress callback.
        case running(done: Int, total: Int)
        case result(DemoResult)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var selectedDemo: Demo = .shelfInventory
    /// Bumps each time a new result is published — lets the view re-trigger translation.
    @Published private(set) var resultCount = 0

    let demos = Demo.all

    // Default preset (~3 GB). Swap for `.smolVLM2` to test with a smaller, faster download.
    private let backend = MLXSwiftBackend(profile: .qwen3VL4B)
    private lazy var runner = VLMRunner(backend: backend)
    private var didStartLoading = false

    var modelName: String { backend.profile.displayName }
    var hasImage: Bool { capturedImage != nil }
    var isBusy: Bool {
        switch phase {
        case .preparing, .downloading, .running: true
        default: false
        }
    }

    /// Load the model once. Uses a model sideloaded via USB if present
    /// (`Documents/Model`); otherwise downloads the preset from Hugging Face.
    func loadModelIfNeeded() async {
        guard !didStartLoading else { return }
        didStartLoading = true
        do {
            if let local = Self.sideloadedModelDirectory() {
                try await backend.load(from: local)
            } else {
                try await backend.load { [weak self] fraction in
                    Task { @MainActor in self?.phase = .downloading(fraction) }
                }
            }
            phase = .ready
        } catch {
            phase = .failed("Model load failed: \(error)")
        }
    }

    /// Switch demos: keep the loaded model and the current photo, drop the old result.
    func select(_ demo: Demo) {
        guard !isBusy, demo.id != selectedDemo.id else { return }
        selectedDemo = demo
        switch phase {
        case .result, .failed: phase = .ready
        default: break
        }
    }

    /// Run the selected demo on a freshly captured image.
    func analyze(_ image: UIImage, detail: Int, query: String) async {
        capturedImage = image
        await analyzeCurrent(detail: detail, query: query)
    }

    /// (Re)run the selected demo on the current photo — e.g. after switching demos.
    func analyzeCurrent(detail: Int, query: String) async {
        guard let uiImage = capturedImage,
              let vlmImage = VLMImage(uiImage: uiImage.normalizedUp()) else {
            phase = .failed("Could not read the image.")
            return
        }
        phase = .running(done: 0, total: 0)
        let demo = selectedDemo
        do {
            let result = try await demo.run(vlmImage, runner, detail, query) { [weak self] done, total in
                Task { @MainActor in self?.phase = .running(done: done, total: total) }
            }
            phase = .result(result)
            resultCount += 1
        } catch {
            phase = .failed("Analysis failed: \(error)")
        }
    }

    /// A model folder sideloaded onto the device via USB into the app's Documents
    /// directory: `Documents/Model` containing the model's `config.json` and weights.
    /// Returns `nil` to fall back to the Hub download.
    private static func sideloadedModelDirectory() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Model", isDirectory: true)
        return fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) ? dir : nil
    }
}

private extension UIImage {
    /// Bake EXIF orientation into pixels — `VLMImage` reads the raw `CGImage`, so a
    /// camera photo must be uprighted before tiling or the VLM sees it rotated.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
