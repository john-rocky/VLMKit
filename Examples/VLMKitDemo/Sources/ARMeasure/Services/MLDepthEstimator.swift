//
//  MLDepthEstimator.swift
//  ProductMeasure
//

import ARKit
import CoreML
import Vision

/// ML-based depth estimation using DepthAnything V2 Small
/// Produces relative depth maps calibrated to metric scale via ARKit raycast
class MLDepthEstimator: DepthSource {
    let isMetric = false
    let hasConfidenceMap = false

    // MARK: - Model

    private var visionModel: VNCoreMLModel?
    private var isModelLoaded = false

    // MARK: - Cache

    private var cachedDepthMap: CVPixelBuffer?
    private var cachedTimestamp: TimeInterval = 0

    // MARK: - Calibration

    private(set) var isCalibrated: Bool = false
    private var scaleFactor: Float = 1.0
    /// Exponential moving average alpha for scale smoothing
    private let emaAlpha: Float = 0.3

    // MARK: - Init

    init() {
        loadModel()
    }

    private func loadModel() {
        guard let modelURL = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
            #if DEBUG
            print("[MLDepth] Model file not found in bundle")
            #endif
            return
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            visionModel = try VNCoreMLModel(for: mlModel)
            isModelLoaded = true
            #if DEBUG
            print("[MLDepth] Model loaded successfully")
            #endif
        } catch {
            #if DEBUG
            print("[MLDepth] Failed to load model: \(error)")
            #endif
        }
    }

    // MARK: - DepthSource

    func depthMap(for frame: ARFrame) -> CVPixelBuffer? {
        // Return cached if same frame
        if frame.timestamp == cachedTimestamp, let cached = cachedDepthMap {
            return cached
        }
        return runInference(frame: frame)
    }

    func confidenceMap(for frame: ARFrame) -> CVPixelBuffer? {
        nil // ML depth has no confidence map
    }

    // MARK: - Calibration

    /// Calibrate scale using a known absolute distance from ARKit raycast
    /// - Parameters:
    ///   - raycastDistance: Absolute distance in meters from raycast
    ///   - normalizedPoint: Point in normalized image coordinates (0-1, Vision convention)
    ///   - frame: Current ARFrame
    func calibrate(raycastDistance: Float, normalizedPoint: CGPoint, frame: ARFrame) {
        guard let depthMap = depthMap(for: frame) else { return }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        // Vision normalized coords: origin bottom-left
        let px = Int(normalizedPoint.x * CGFloat(width))
        let py = Int((1.0 - normalizedPoint.y) * CGFloat(height))

        guard px >= 0, px < width, py >= 0, py < height else { return }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }

        let stride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let relativeDepth = base.assumingMemoryBound(to: Float32.self)[py * stride + px]

        guard relativeDepth.isFinite, relativeDepth > 0.001 else { return }

        // relativeDepth is inverse depth (higher = closer)
        // metricDepth = scaleFactor / relativeDepth
        let newScale = raycastDistance * relativeDepth

        if isCalibrated {
            // EMA smoothing
            scaleFactor = emaAlpha * newScale + (1.0 - emaAlpha) * scaleFactor
        } else {
            scaleFactor = newScale
            isCalibrated = true
        }

        #if DEBUG
        print("[MLDepth] Calibrated: scale=\(scaleFactor), raycast=\(raycastDistance)m, relative=\(relativeDepth)")
        #endif
    }

    // MARK: - Inference

    private func runInference(frame: ARFrame) -> CVPixelBuffer? {
        guard isModelLoaded, let model = visionModel else { return nil }

        let pixelBuffer = frame.capturedImage

        // Create and run Vision request synchronously
        var resultBuffer: CVPixelBuffer?

        let request = VNCoreMLRequest(model: model) { req, _ in
            guard let observation = req.results?.first as? VNPixelBufferObservation else {
                // Try as feature value
                if let featureObs = req.results?.first as? VNCoreMLFeatureValueObservation,
                   let multiArray = featureObs.featureValue.multiArrayValue {
                    resultBuffer = self.multiArrayToDepthBuffer(multiArray)
                }
                return
            }
            resultBuffer = observation.pixelBuffer
        }

        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            #if DEBUG
            print("[MLDepth] Inference failed: \(error)")
            #endif
            return nil
        }

        guard let rawDepth = resultBuffer else { return nil }

        // Apply scale calibration if available
        let calibrated = applyCalibration(rawDepth)

        cachedDepthMap = calibrated
        cachedTimestamp = frame.timestamp
        return calibrated
    }

    /// Convert MLMultiArray output to CVPixelBuffer (Float32 depth map)
    private func multiArrayToDepthBuffer(_ multiArray: MLMultiArray) -> CVPixelBuffer? {
        let shape = multiArray.shape.map { $0.intValue }
        // Expect [1, H, W] or [H, W]
        let height: Int
        let width: Int
        if shape.count == 3 {
            height = shape[1]
            width = shape[2]
        } else if shape.count == 2 {
            height = shape[0]
            width = shape[1]
        } else {
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_DepthFloat32, nil, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let dest = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let destPtr = dest.assumingMemoryBound(to: Float32.self)
        let destStride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.size

        let srcPtr = multiArray.dataPointer.assumingMemoryBound(to: Float32.self)
        for y in 0..<height {
            for x in 0..<width {
                destPtr[y * destStride + x] = srcPtr[y * width + x]
            }
        }
        return buffer
    }

    /// Apply scale calibration: convert relative inverse depth to metric depth
    private func applyCalibration(_ rawDepth: CVPixelBuffer) -> CVPixelBuffer {
        guard isCalibrated else { return rawDepth }

        let width = CVPixelBufferGetWidth(rawDepth)
        let height = CVPixelBufferGetHeight(rawDepth)

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_DepthFloat32, nil, &outputBuffer)
        guard let output = outputBuffer else { return rawDepth }

        CVPixelBufferLockBaseAddress(rawDepth, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(rawDepth, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(rawDepth),
              let dstBase = CVPixelBufferGetBaseAddress(output) else { return rawDepth }

        let srcPtr = srcBase.assumingMemoryBound(to: Float32.self)
        let dstPtr = dstBase.assumingMemoryBound(to: Float32.self)
        let srcStride = CVPixelBufferGetBytesPerRow(rawDepth) / MemoryLayout<Float32>.size
        let dstStride = CVPixelBufferGetBytesPerRow(output) / MemoryLayout<Float32>.size

        for y in 0..<height {
            for x in 0..<width {
                let rel = srcPtr[y * srcStride + x]
                if rel.isFinite && rel > 0.001 {
                    dstPtr[y * dstStride + x] = scaleFactor / rel
                } else {
                    dstPtr[y * dstStride + x] = 0
                }
            }
        }

        return output
    }
}
