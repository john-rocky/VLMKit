import CoreML
import Foundation

/// Minimal driver for HyperSD's chunked Unet. apple/ml-stable-diffusion ships
/// a `Unet` wrapper but its `predictNoise(...)` is `internal`, so we drive the
/// two `.mlpackage` chunks directly with `MLModel`. Pipeline order:
///
///   chunk1(sample, timestep, encoder_hidden_states) → intermediate features
///   chunk2(chunk1_outputs ∪ original_inputs)        → noise prediction
///
/// The merge step matches apple/ml-stable-diffusion's chunk-pipelining (each
/// stage sees both the previous stage's outputs and the original Unet inputs).
@available(iOS 16.2, *)
final class MiniUnet {
    private let chunk1URL: URL
    private let chunk2URL: URL
    private let configuration: MLModelConfiguration
    private var chunk1: MLModel?
    private var chunk2: MLModel?

    init(chunk1URL: URL, chunk2URL: URL, configuration: MLModelConfiguration) {
        self.chunk1URL = chunk1URL
        self.chunk2URL = chunk2URL
        self.configuration = configuration
    }

    func loadResources() throws {
        if chunk1 == nil { chunk1 = try MLModel(contentsOf: chunk1URL, configuration: configuration) }
        if chunk2 == nil { chunk2 = try MLModel(contentsOf: chunk2URL, configuration: configuration) }
    }

    func unloadResources() {
        chunk1 = nil
        chunk2 = nil
    }

    /// Expected `sample` input shape (incl. CFG batch dim) of the loaded chunk1.
    /// HyperSD checkpoints converted with apple/ml-stable-diffusion are
    /// compiled with batch=2 even when guidance is off — see
    /// `HyperSDPipeline.generate` for how we feed the duplicated batch.
    var sampleShape: [Int] {
        get throws {
            try loadResources()
            return chunk1!
                .modelDescription
                .inputDescriptionsByName["sample"]?
                .multiArrayConstraint?
                .shape
                .map { $0.intValue } ?? [2, 4, 64, 64]
        }
    }

    /// Run one denoising-step noise prediction. `sample`, `hiddenStates`, and
    /// the returned noise tensor all carry the batch dim the compiled model
    /// expects (typically 2 for CFG-on conversions; the caller duplicates the
    /// single conditional sample/hidden state into the batch).
    func predictNoise(
        sample: MLShapedArray<Float32>,
        timeStep: Int,
        hiddenStates: MLShapedArray<Float32>
    ) throws -> MLShapedArray<Float32> {
        try loadResources()
        let batchSize = sample.shape[0]
        let timestepArray = MLShapedArray<Float32>(
            scalars: [Float](repeating: Float(timeStep), count: batchSize),
            shape: [batchSize]
        )

        let originalInputs: [String: MLFeatureValue] = [
            "sample": MLFeatureValue(multiArray: MLMultiArray(sample)),
            "timestep": MLFeatureValue(multiArray: MLMultiArray(timestepArray)),
            "encoder_hidden_states": MLFeatureValue(multiArray: MLMultiArray(hiddenStates)),
        ]

        let chunk1Input = try MLDictionaryFeatureProvider(
            dictionary: originalInputs.mapValues { $0 as Any }
        )
        let chunk1Output = try chunk1!.prediction(from: chunk1Input)

        // Merge chunk1 outputs with original inputs (chunk1 outputs take
        // precedence on name collisions). Matches apple/ml-stable-diffusion
        // `Unet.predictions(from:)`.
        var chunk2Dict: [String: Any] = [:]
        for name in chunk1Output.featureNames {
            chunk2Dict[name] = chunk1Output.featureValue(for: name) as Any
        }
        for (name, value) in originalInputs where chunk2Dict[name] == nil {
            chunk2Dict[name] = value
        }

        let chunk2Input = try MLDictionaryFeatureProvider(dictionary: chunk2Dict)
        let chunk2Output = try chunk2!.prediction(from: chunk2Input)

        // The noise tensor is the first (and typically only) output of chunk2.
        guard
            let outputName = chunk2Output.featureNames.first,
            let multiArray = chunk2Output.featureValue(for: outputName)?.multiArrayValue
        else {
            throw HyperSDError.unetPredictionFailed
        }
        // Convert to Float32 in case the model output dtype is fp16.
        let fp32 = MLMultiArray(concatenating: [multiArray], axis: 0, dataType: .float32)
        return MLShapedArray<Float32>(fp32)
    }
}
