import UIKit
import os

/// AI Diffusion background generator powered by HyperSD (1-step distilled
/// SD 1.5). Holds the loaded `HyperSDPipeline` across `generate` calls so
/// switching candidates inside one Background Studio session doesn't cold-load
/// the ~2 GB of weights every time. `unload()` (called by
/// `BackgroundStudio.reset()`) drops the pipeline so the VLM can reclaim RAM
/// when the sheet closes.
@MainActor
final class HyperSDBackground: BackgroundGenerator {

    private var pipeline: HyperSDPipeline?
    private let downloader = HyperSDDownloader()

    /// Fetch any missing mlpackages from the release. Cheap no-op when all
    /// four bundles are already on disk (the downloader skips present
    /// assets). `onProgress` runs on whatever actor `BackgroundStudio`
    /// passes — currently the main actor, so the studio's `@Published`
    /// phase can update directly.
    func downloadIfNeeded(
        onProgress: @escaping @Sendable (HyperSDDownloader.Update) -> Void
    ) async throws {
        try await downloader.downloadIfNeeded(
            into: Self.modelDirectory, onProgress: onProgress
        )
    }

    // MARK: - BackgroundGenerator

    func generate(
        style: String,
        count: Int,
        canvasSize: CGSize
    ) async throws -> [UIImage] {
        // Free the VLM before we touch HyperSD so the on-device GPU/RAM is
        // ours. The next VLM call (refine / suggest) pays a cold-load.
        await SharedVLM.unload()

        let pipeline = try makeOrReusePipeline()

        // Hand the actual compute to a detached task so the @MainActor that
        // owns the studio isn't blocked while the Unet + VAE crunch the
        // tensors (~1-2 s on an A17 Pro per image).
        let prompt = Self.buildPrompt(from: style)
        let images = try await Task.detached(priority: .userInitiated) {
            var results: [CGImage] = []
            results.reserveCapacity(count)
            for _ in 0..<count {
                let cg = try pipeline.generate(prompt: prompt, seed: nil)
                results.append(cg)
            }
            return results
        }.value

        return images.map { UIImage(cgImage: $0) }
    }

    // MARK: - Lifecycle

    /// Drop the loaded pipeline. The Background Studio sheet calls this on
    /// dismiss; the next user gesture that needs HyperSD will cold-load again.
    func unload() {
        pipeline?.unloadResources()
        pipeline = nil
    }

    private func makeOrReusePipeline() throws -> HyperSDPipeline {
        if let pipeline { return pipeline }
        let pipeline = try HyperSDPipeline(modelDirectory: Self.modelDirectory)
        self.pipeline = pipeline
        return pipeline
    }

    // MARK: - Availability

    /// Runtime gate for `BackgroundMode.diffusion`. Checks the device class
    /// only — models that are missing are *downloadable* now, not a blocker.
    /// `nonisolated` because `BackgroundMode` reads it from view code that
    /// hops off the main actor.
    nonisolated static var isAvailable: Bool {
        guard ProcessInfo.processInfo.physicalMemory >= UInt64(6) * 1024 * 1024 * 1024 else {
            return false
        }
        // `os_proc_available_memory()` is the bytes-before-jetsam estimate
        // the kernel hands back to us (requires the increased-memory-limit
        // entitlement, which the app already sets). HyperSD weights peak
        // around 2 GB during the first Unet pass; require a bit of headroom.
        let available = os_proc_available_memory()
        return available == 0 || available >= 2 * 1024 * 1024 * 1024
    }

    /// `Documents/HyperSDModels/` where the downloader stages the 4
    /// mlpackages. Always returns the URL — callers should pair this with
    /// `areModelsPresent` to decide whether they need to download first.
    nonisolated static var modelDirectory: URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("HyperSDModels", isDirectory: true)
    }

    /// Are all 4 mlpackage bundles already on disk? The downloader writes
    /// them atomically (unzip into a tmp sibling then rename) so a "present"
    /// directory is a usable directory.
    nonisolated static var areModelsPresent: Bool {
        let fm = FileManager.default
        let dir = modelDirectory
        for name in [
            HyperSDPipeline.Resources.textEncoderName,
            HyperSDPipeline.Resources.unetChunk1Name,
            HyperSDPipeline.Resources.unetChunk2Name,
            HyperSDPipeline.Resources.decoderName,
        ] {
            if !fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
                return false
            }
        }
        return true
    }

    // MARK: - Prompt shaping

    /// Wrap the VLM's free-text style hint with a few words that nudge the
    /// model toward product-photography backgrounds (no people, no text,
    /// clean surfaces) without crowding the user's intent.
    private static func buildPrompt(from style: String) -> String {
        let trimmed = style.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "clean studio backdrop, soft light, product photography"
        }
        return "\(trimmed), product photography backdrop, soft light, no text, no people"
    }
}
