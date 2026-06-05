import CoreML
import CoreGraphics
import Foundation
import StableDiffusion

/// On-device HyperSD (1-step distilled Stable Diffusion 1.5) pipeline.
/// `StableDiffusionPipeline` from apple/ml-stable-diffusion can't run TCD
/// (its scheduler enum is closed), so this drives the public building blocks
/// (`TextEncoder`, `Decoder`, `BPETokenizer`) plus a custom 1-step TCD step
/// and a hand-rolled `MiniUnet` directly.
///
/// One generation = encode prompt → seed Gaussian latents → Unet noise
/// prediction (1 step) → TCD `pred_x0` → VAE decode → CGImage.
/// Not marked `@MainActor` so the heavy CoreML work runs off the main
/// thread when invoked from `Task.detached { … }`. `@unchecked Sendable`
/// because callers only ever own and drive a single instance sequentially
/// (one Background Studio sheet at a time).
@available(iOS 16.2, *)
final class HyperSDPipeline: @unchecked Sendable {

    private enum Constants {
        static let latentChannels = 4
        static let latentSize = 64       // 512×512 image / 8 VAE downsample
        static let decoderScaleFactor: Float32 = 0.18215
    }

    private let modelDirectory: URL
    private let mlConfiguration: MLModelConfiguration
    private var tokenizer: BPETokenizer?
    private var textEncoder: TextEncoder?
    /// Deferred until `loadResources()` so we can pass the compiled
    /// `.mlmodelc` URLs to MiniUnet. Compile-on-first-launch is too
    /// expensive (~5–15 s on a real device) to run on the main actor
    /// inside `init`.
    private var unet: MiniUnet?
    private var decoder: Decoder?

    init(modelDirectory: URL) throws {
        let urls = try Resources(modelDirectory: modelDirectory)
        try urls.validate()
        self.modelDirectory = modelDirectory
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        self.mlConfiguration = config
    }

    /// Eagerly load all four models + tokenizer. Called by `generate` if the
    /// pipeline hasn't been warmed up. First call on a fresh install will
    /// also compile each `.mlpackage` into `.mlmodelc` (CoreML's runtime
    /// requires the compiled form on iOS) and cache the result next to the
    /// source bundle — subsequent launches skip the compile step.
    func loadResources() throws {
        let urls = try Resources(modelDirectory: modelDirectory)
        let textEncoderURL = try Self.compileIfNeeded(at: urls.textEncoder)
        let unetChunk1URL = try Self.compileIfNeeded(at: urls.unetChunk1)
        let unetChunk2URL = try Self.compileIfNeeded(at: urls.unetChunk2)
        let decoderURL = try Self.compileIfNeeded(at: urls.decoder)

        if tokenizer == nil {
            tokenizer = try BPETokenizer(mergesAt: urls.merges, vocabularyAt: urls.vocab)
        }
        if textEncoder == nil {
            let encoder = TextEncoder(
                tokenizer: tokenizer!,
                modelAt: textEncoderURL,
                configuration: mlConfiguration
            )
            try encoder.loadResources()
            textEncoder = encoder
        }
        if unet == nil {
            unet = MiniUnet(
                chunk1URL: unetChunk1URL,
                chunk2URL: unetChunk2URL,
                configuration: mlConfiguration
            )
        }
        try unet!.loadResources()
        if decoder == nil {
            let d = Decoder(modelAt: decoderURL, configuration: mlConfiguration)
            try d.loadResources()
            decoder = d
        }
    }

    /// Drop every loaded model + tokenizer so the next `generate` cold-loads.
    /// Called when the Background Studio sheet is dismissed so the VLM can
    /// reclaim the ~2 GB of HyperSD weights.
    func unloadResources() {
        textEncoder?.unloadResources()
        unet?.unloadResources()
        decoder?.unloadResources()
        textEncoder = nil
        unet = nil
        decoder = nil
        tokenizer = nil
    }

    // MARK: - Compile cache

    /// Look for a sibling `.mlmodelc` next to `packageURL`; if missing,
    /// run CoreML's on-device compiler on the `.mlpackage` and move the
    /// resulting bundle into place.
    ///
    /// `MLModel.compileModel(at:)` writes into a temp directory the OS may
    /// reclaim, so we always move it under `HyperSDModels/` for persistence
    /// across launches. If the source URL already points at a `.mlmodelc`
    /// (a future downloader could ship pre-compiled bundles) we return it
    /// as-is.
    private static func compileIfNeeded(at packageURL: URL) throws -> URL {
        let fm = FileManager.default
        if packageURL.pathExtension == "mlmodelc" { return packageURL }
        let parent = packageURL.deletingLastPathComponent()
        let baseName = packageURL.deletingPathExtension().lastPathComponent
        let compiled = parent.appendingPathComponent(baseName + ".mlmodelc")
        if fm.fileExists(atPath: compiled.path) { return compiled }

        guard fm.fileExists(atPath: packageURL.path) else {
            throw HyperSDError.modelsMissing(packageURL.lastPathComponent)
        }
        let tempCompiled = try MLModel.compileModel(at: packageURL)
        if fm.fileExists(atPath: compiled.path) {
            try? fm.removeItem(at: compiled)
        }
        try fm.moveItem(at: tempCompiled, to: compiled)
        return compiled
    }

    /// Generate a single 512×512 image. `negativePrompt` defaults to empty —
    /// guidance is fixed at 1.0 (no CFG amplification) per HyperSD's training,
    /// so the negative branch is computed but ignored. `seed` makes the noise
    /// reproducible; `nil` picks a random seed.
    func generate(
        prompt: String,
        negativePrompt: String = "",
        seed: UInt32? = nil
    ) throws -> CGImage {
        try loadResources()
        guard let textEncoder = textEncoder, let unet = unet, let decoder = decoder else {
            throw HyperSDError.modelsNotLoaded
        }

        // 1. Text encode positive + negative prompts and pack into the
        //    [B=2, 768, 1, 77] hidden-states layout the Unet expects.
        let positive = try textEncoder.encode(prompt)
        let negative = try textEncoder.encode(negativePrompt)
        let concat = MLShapedArray<Float32>(
            concatenating: [negative, positive], alongAxis: 0
        )
        let hiddenStates = Self.toHiddenStates(concat)

        // 2. Seed Gaussian noise for the latent.
        let scheduler = TCDScheduler(stepCount: 1)
        let resolvedSeed = seed.map { UInt64($0) } ?? UInt64.random(in: 1...UInt64.max)
        var rng = SeededRNG(seed: resolvedSeed)
        let singleLatent = Self.gaussianNoise(
            shape: [1, Constants.latentChannels, Constants.latentSize, Constants.latentSize],
            sigma: Double(scheduler.initNoiseSigma),
            rng: &rng
        )

        // 3. Duplicate the latent into the CFG batch dim the model was
        //    compiled for, even though we don't amplify guidance.
        let batched = MLShapedArray<Float32>(
            concatenating: [singleLatent, singleLatent], alongAxis: 0
        )

        // 4. Single Unet noise prediction; pull the conditional (index 1)
        //    branch out for the TCD step (guidance = 1 → unconditional unused).
        let t = scheduler.timeSteps[0]
        let noiseBatched = try unet.predictNoise(
            sample: batched, timeStep: t, hiddenStates: hiddenStates
        )
        let noise = Self.sliceBatch(noiseBatched, index: 1)

        // 5. One TCD step gives the predicted clean latent.
        let denoised = scheduler.step(output: noise, timeStep: t, sample: singleLatent)

        // 6. VAE decode → CGImage. apple/ml-stable-diffusion's Decoder applies
        //    the scaleFactor divisor internally.
        let images = try decoder.decode([denoised], scaleFactor: Constants.decoderScaleFactor)
        guard let cg = images.first else { throw HyperSDError.decodeFailed }
        return cg
    }

    // MARK: - Helpers

    /// `[B, 77, 768]` → `[B, 768, 1, 77]`. Matches apple/ml-stable-diffusion's
    /// `StableDiffusionPipeline.toHiddenStates` so the Unet's compiled input
    /// layout lines up.
    private static func toHiddenStates(_ embedding: MLShapedArray<Float32>) -> MLShapedArray<Float32> {
        let fromShape = embedding.shape
        let stateShape = [fromShape[0], fromShape[2], 1, fromShape[1]]
        var states = MLShapedArray<Float32>(repeating: Float32(0), shape: stateShape)
        for i0 in 0..<fromShape[0] {
            for i1 in 0..<fromShape[1] {
                for i2 in 0..<fromShape[2] {
                    states[scalarAt: i0, i2, 0, i1] = embedding[scalarAt: i0, i1, i2]
                }
            }
        }
        return states
    }

    /// Extract one item from a batched shape's first axis into a fresh
    /// `[1, ...]` shape.
    private static func sliceBatch(_ x: MLShapedArray<Float32>, index: Int) -> MLShapedArray<Float32> {
        var resultShape = x.shape
        resultShape[0] = 1
        let scalarsPerBatch = x.scalarCount / x.shape[0]
        return MLShapedArray(unsafeUninitializedShape: resultShape) { scalars, _ in
            x.withUnsafeShapedBufferPointer { buf, _, _ in
                let start = index * scalarsPerBatch
                for i in 0..<scalarsPerBatch {
                    scalars.initializeElement(at: i, to: buf[start + i])
                }
            }
        }
    }

    private static func gaussianNoise(
        shape: [Int],
        sigma: Double,
        rng: inout SeededRNG
    ) -> MLShapedArray<Float32> {
        let n = shape.reduce(1, *)
        var values: [Float32] = []
        values.reserveCapacity(n)
        var i = 0
        while i < n {
            // Box-Muller — two normals per uniform pair.
            let u1 = max(Double.random(in: 0..<1, using: &rng), 1e-10)
            let u2 = Double.random(in: 0..<1, using: &rng)
            let r = (-2.0 * log(u1)).squareRoot() * sigma
            let theta = 2 * .pi * u2
            values.append(Float32(r * cos(theta)))
            i += 1
            if i < n {
                values.append(Float32(r * sin(theta)))
                i += 1
            }
        }
        return MLShapedArray(scalars: values, shape: shape)
    }

    // MARK: - Resources

    /// Where each on-disk resource lives. The 4 mlpackages sit in the
    /// per-app sideload / download directory under Documents; the BPE
    /// tokenizer (vocab + merges) is bundled into the app binary because
    /// it's tiny, stable across SD 1.5 builds, and not in the release.
    struct Resources {
        let textEncoder: URL
        let unetChunk1: URL
        let unetChunk2: URL
        let decoder: URL
        let vocab: URL
        let merges: URL

        /// File names used by the `john-rocky/CoreML-Models` `hypersd-v1`
        /// release. Kept here as the single source of truth — the downloader
        /// references the same names when picking unzip targets.
        static let textEncoderName = "HyperSDTextEncoder.mlpackage"
        static let unetChunk1Name = "HyperSDUnetChunk1.mlpackage"
        static let unetChunk2Name = "HyperSDUnetChunk2.mlpackage"
        static let decoderName = "HyperSDVAEDecoder.mlpackage"

        init(modelDirectory: URL) throws {
            textEncoder = modelDirectory.appendingPathComponent(Self.textEncoderName)
            unetChunk1 = modelDirectory.appendingPathComponent(Self.unetChunk1Name)
            unetChunk2 = modelDirectory.appendingPathComponent(Self.unetChunk2Name)
            decoder = modelDirectory.appendingPathComponent(Self.decoderName)
            guard
                let vocabURL = Bundle.main.url(forResource: "hypersd_vocab", withExtension: "json"),
                let mergesURL = Bundle.main.url(forResource: "hypersd_merges", withExtension: "txt")
            else {
                throw HyperSDError.modelsMissing(
                    "Bundled tokenizer files (hypersd_vocab.json / hypersd_merges.txt)"
                )
            }
            vocab = vocabURL
            merges = mergesURL
        }

        func validate() throws {
            let fm = FileManager.default
            for url in [textEncoder, unetChunk1, unetChunk2, decoder, vocab, merges] {
                guard fm.fileExists(atPath: url.path) else {
                    throw HyperSDError.modelsMissing(url.lastPathComponent)
                }
            }
        }
    }
}

// MARK: - Errors

enum HyperSDError: LocalizedError {
    case modelsMissing(String)
    case modelsNotLoaded
    case unetPredictionFailed
    case decodeFailed
    case downloadFailed(String)
    case unzipFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelsMissing(let name):
            return "HyperSD model file missing: \(name)"
        case .modelsNotLoaded:
            return "HyperSD pipeline was used before its resources finished loading."
        case .unetPredictionFailed:
            return "HyperSD Unet returned no noise output."
        case .decodeFailed:
            return "HyperSD VAE decode returned no image."
        case .downloadFailed(let name):
            return "Could not download HyperSD asset: \(name)"
        case .unzipFailed(let name):
            return "Could not extract HyperSD asset: \(name)"
        }
    }
}

// MARK: - Seeded RNG

/// SplitMix64-backed `RandomNumberGenerator` so the noise tensor is
/// reproducible for a given seed. Box-Muller (in `gaussianNoise`) draws two
/// uniforms per emitted normal.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 1 : seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
