import Accelerate
import CoreML

/// Trajectory Consistency Distillation scheduler — the 1-step denoising
/// formula HyperSD's distilled checkpoint expects. Mirrors HuggingFace
/// diffusers' `TCDScheduler` with `eta = 1.0`. Ported from the standalone
/// HyperSDDemo (same author); we don't conform to apple/ml-stable-diffusion's
/// `Scheduler` protocol because the rest of this file's call site bypasses
/// that pipeline entirely (see `HyperSDPipeline.swift`).
///
/// One-step semantics:
///   `pred_x0 = (sample - sqrt(1 - α_t) * model_output) / sqrt(α_t)`
///
/// where `α_t` is `alphasCumProd[t]`, `model_output` is the Unet noise
/// prediction, and `sample` is the noisy latent fed to the Unet. With a
/// single step, `pred_x0` is the final denoised latent — pass it straight to
/// the VAE decoder.
@available(iOS 16.2, *)
final class TCDScheduler {

    enum BetaSchedule {
        case linear
        case scaledLinear
    }

    let trainStepCount: Int
    let inferenceStepCount: Int
    let alphasCumProd: [Float]
    let timeSteps: [Int]

    /// Standard deviation of the initial noise — unit Gaussian for SD 1.5.
    var initNoiseSigma: Float { 1.0 }

    init(
        stepCount: Int = 1,
        trainStepCount: Int = 1000,
        betaSchedule: BetaSchedule = .scaledLinear,
        betaStart: Float = 0.00085,
        betaEnd: Float = 0.012
    ) {
        self.trainStepCount = trainStepCount
        self.inferenceStepCount = stepCount

        let betas: [Float]
        switch betaSchedule {
        case .linear:
            betas = Self.linspace(betaStart, betaEnd, trainStepCount)
        case .scaledLinear:
            betas = Self.linspace(betaStart.squareRoot(), betaEnd.squareRoot(), trainStepCount)
                .map { $0 * $0 }
        }
        let alphas = betas.map { 1.0 - $0 }
        var cumProd = alphas
        for i in 1..<cumProd.count { cumProd[i] *= cumProd[i - 1] }
        self.alphasCumProd = cumProd

        // Trailing timesteps (matches diffusers' TCDScheduler).
        let stepRatio = Float(trainStepCount) / Float(stepCount)
        self.timeSteps = stride(from: Float(stepCount), through: 1, by: -1)
            .map { Int(($0 * stepRatio).rounded()) - 1 }
    }

    /// One TCD step. With `eta = 1.0` and a single inference step this is
    /// simply `pred_x0` — see file header for the formula.
    func step(
        output: MLShapedArray<Float32>,
        timeStep t: Int,
        sample s: MLShapedArray<Float32>
    ) -> MLShapedArray<Float32> {
        let alphaProdT = alphasCumProd[t]
        let sqrtAlpha = alphaProdT.squareRoot()
        let sqrtBeta = (1 - alphaProdT).squareRoot()
        let scalarCount = s.scalarCount

        return MLShapedArray(unsafeUninitializedShape: s.shape) { scalars, _ in
            s.withUnsafeShapedBufferPointer { sampleBuf, _, _ in
                output.withUnsafeShapedBufferPointer { outputBuf, _, _ in
                    for i in 0..<scalarCount {
                        let predX0 = (sampleBuf[i] - sqrtBeta * outputBuf[i]) / sqrtAlpha
                        scalars.initializeElement(at: i, to: predX0)
                    }
                }
            }
        }
    }

    private static func linspace(_ start: Float, _ end: Float, _ count: Int) -> [Float] {
        let scale = (end - start) / Float(count - 1)
        return (0..<count).map { Float($0) * scale + start }
    }
}
