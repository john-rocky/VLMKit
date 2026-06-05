import Foundation
import VLMKit

/// Process-wide singleton backend + runner so that the SwiftUI app and any
/// App Intents (Shortcuts / Siri) share one ~3 GB model load. Without this each
/// AppIntent invocation could try to load a second copy of the weights and
/// jetsam the process. `loadIfNeeded` is idempotent — call it from every entry
/// point that needs the model.
///
/// Same sideload-from-`Documents/Model` fallback as `DemoViewModel`; if neither
/// the sideloaded directory nor the network are available, `load` throws.
@MainActor
enum SharedVLM {
    static let backend = MLXSwiftBackend(profile: .qwen3VL4B)
    static let runner = VLMRunner(backend: backend)

    /// In-flight load task, shared by every concurrent caller of `loadIfNeeded`.
    /// `nil` means "not started yet" OR "previous attempt failed — retry next
    /// call". A finished, successful task stays here so subsequent callers
    /// immediately get `task.value` (a noop after completion).
    private static var loadTask: Task<Void, Error>?

    static var modelName: String { backend.profile.displayName }

    /// Load the model once per process. Concurrent callers all await the same
    /// in-flight task, so a describe call that races the app-launch preload no
    /// longer sees an empty `container` and skips inference.
    static func loadIfNeeded(onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        if let task = loadTask {
            try await task.value
            return
        }
        let task = Task { try await performLoad(onProgress: onProgress) }
        loadTask = task
        do {
            try await task.value
        } catch {
            // Allow the next caller to retry from scratch.
            loadTask = nil
            throw error
        }
    }

    private static func performLoad(onProgress: (@Sendable (Double) -> Void)?) async throws {
        if let local = sideloadedModelDirectory() {
            try await backend.load(from: local)
        } else {
            try await backend.load(onProgress: onProgress)
        }
    }

    /// Drop the loaded VLM so an on-device pipeline that wants the GPU/RAM
    /// (Background Studio's Diffusion mode) can take it. The next
    /// `loadIfNeeded` cold-loads from disk again (~30 s on first run after
    /// this).
    static func unload() async {
        loadTask = nil
        await backend.unload()
    }

    /// A model folder sideloaded onto the device via USB into the app's Documents
    /// directory: `Documents/Model/config.json` + weights. Returns `nil` to fall
    /// back to the Hub download.
    private static func sideloadedModelDirectory() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Model", isDirectory: true)
        return fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) ? dir : nil
    }
}
