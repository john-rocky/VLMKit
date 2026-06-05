//
//  InstanceSegmentationService.swift
//  SnapMeasure
//

import Vision
import CoreImage
import UIKit
import ARKit

/// Service for performing instance segmentation using Vision framework
class InstanceSegmentationService {
    // MARK: - Types

    struct SegmentationResult {
        /// The mask for the selected instance (CVPixelBuffer)
        let mask: CVPixelBuffer

        /// Bounding box of the instance in normalized coordinates (0-1)
        let boundingBox: CGRect

        /// Size of the mask
        let maskSize: CGSize

        #if DEBUG
        /// Number of foreground instances detected
        var instanceCount: Int = 0
        #endif
    }

    // MARK: - Properties

    private let ciContext = CIContext()

    // MARK: - Public Methods

    /// Segment the foreground object at the given tap location
    /// - Parameters:
    ///   - pixelBuffer: The camera image pixel buffer
    ///   - tapPoint: Tap location in normalized image coordinates (0-1, origin top-left)
    /// - Returns: SegmentationResult if an instance is found at the tap point
    func segmentInstance(
        in pixelBuffer: CVPixelBuffer,
        at tapPoint: CGPoint,
        depthMap: CVPixelBuffer? = nil
    ) async throws -> SegmentationResult? {
#if DEBUG
        print("[Segmentation] Starting segmentation at point: \(tapPoint)")
#endif

        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
#if DEBUG
        print("[Segmentation] Input image size: \(imageWidth)x\(imageHeight)")
#endif

        // Create the foreground instance mask request (iOS 17+)
        let request = VNGenerateForegroundInstanceMaskRequest()

        // Use .up orientation - process image as-is
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        try handler.perform([request])

        guard let observation = request.results?.first else {
#if DEBUG
            print("[Segmentation] No observation results")
#endif
            return nil
        }

        let allInstances = observation.allInstances
#if DEBUG
        print("[Segmentation] Found \(allInstances.count) instances")
#endif

        guard !allInstances.isEmpty else {
#if DEBUG
            print("[Segmentation] No instances found")
#endif
            return nil
        }

        let instancesToMask: IndexSet
        let pipeline = AppConstants.currentPipelineVersion
        if pipeline.useInstanceMaskLookup {
            // Current behavior: instanceMask direct lookup + depth penalty
            let tapDepth: Float? = depthMap.flatMap { Self.sampleDepthFromFrame(at: tapPoint, depthMap: $0) }
            let tappedInstanceId = findInstance(at: tapPoint, in: observation, depthMap: depthMap, tapDepth: tapDepth)

            if let instanceId = tappedInstanceId {
                instancesToMask = IndexSet([instanceId])
#if DEBUG
                print("[Segmentation] Using tapped instance \(instanceId)")
#endif
            } else {
                // Fallback: use all instances — downstream depth/CC refinement will separate objects
                instancesToMask = IndexSet(allInstances)
#if DEBUG
                print("[Segmentation] No instance matched tap point, falling back to ALL \(allInstances.count) instances")
#endif
            }
        } else {
            // Legacy: use ALL instances, skip findInstance entirely
            instancesToMask = IndexSet(allInstances)
#if DEBUG
            print("[Segmentation] Legacy pipeline: using ALL \(allInstances.count) instances")
#endif
        }

        // Generate mask for selected instance(s)
        do {
            let instanceMask = try observation.generateMaskedImage(
                ofInstances: instancesToMask,
                from: handler,
                croppedToInstancesExtent: false
            )

            let maskSize = CGSize(
                width: CVPixelBufferGetWidth(instanceMask),
                height: CVPixelBufferGetHeight(instanceMask)
            )
#if DEBUG
            print("[Segmentation] Generated mask size: \(maskSize)")
            print("[Segmentation] Mask is in portrait orientation (rotated from camera)")
#endif

            var result = SegmentationResult(
                mask: instanceMask,
                boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                maskSize: maskSize
            )
            #if DEBUG
            result.instanceCount = allInstances.count
            #endif
            return result
        } catch {
#if DEBUG
            print("[Segmentation] Failed to generate mask: \(error)")
#endif
            throw error
        }
    }

    /// Segment the foreground object within a specific region of interest
    /// - Parameters:
    ///   - pixelBuffer: The camera image pixel buffer
    ///   - regionOfInterest: ROI in normalized image coordinates (0-1, origin bottom-left for Vision)
    /// - Returns: SegmentationResult if an instance is found in the ROI
    func segmentInstanceWithROI(
        in pixelBuffer: CVPixelBuffer,
        regionOfInterest: CGRect
    ) async throws -> SegmentationResult? {
#if DEBUG
        print("[Segmentation] Starting segmentation with ROI: \(regionOfInterest)")
#endif

        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
#if DEBUG
        print("[Segmentation] Input image size: \(imageWidth)x\(imageHeight)")
#endif

        // Create the foreground instance mask request with ROI
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.regionOfInterest = regionOfInterest

        // Use .up orientation - process image as-is
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        try handler.perform([request])

        guard let observation = request.results?.first else {
#if DEBUG
            print("[Segmentation] No observation results with ROI")
#endif
            return nil
        }

        let allInstances = observation.allInstances
#if DEBUG
        print("[Segmentation] Found \(allInstances.count) instances in ROI")
#endif

        guard !allInstances.isEmpty else {
#if DEBUG
            print("[Segmentation] No instances found in ROI")
#endif
            return nil
        }

#if DEBUG
        print("[Segmentation] Using ALL \(allInstances.count) instances from ROI")
#endif

        do {
            let instanceMask = try observation.generateMaskedImage(
                ofInstances: IndexSet(allInstances),
                from: handler,
                croppedToInstancesExtent: false
            )

            let maskSize = CGSize(
                width: CVPixelBufferGetWidth(instanceMask),
                height: CVPixelBufferGetHeight(instanceMask)
            )
#if DEBUG
            print("[Segmentation] Generated mask size: \(maskSize)")
#endif

            var result = SegmentationResult(
                mask: instanceMask,
                boundingBox: regionOfInterest,
                maskSize: maskSize
            )
            #if DEBUG
            result.instanceCount = allInstances.count
            #endif
            return result
        } catch {
#if DEBUG
            print("[Segmentation] Failed to generate mask with ROI: \(error)")
#endif
            throw error
        }
    }

    // MARK: - Private Methods

    /// Find which instance the user tapped using the observation's instanceMask label map.
    /// Direct pixel lookup — O(1) at tap point, O(searchArea) for nearby search.
    /// Optionally applies depth penalty when multiple candidates are nearby.
    private func findInstance(
        at point: CGPoint,
        in observation: VNInstanceMaskObservation,
        depthMap: CVPixelBuffer? = nil,
        tapDepth: Float? = nil
    ) -> Int? {
        let allInstances = observation.allInstances
        guard !allInstances.isEmpty else { return nil }

        // instanceMask: each pixel value = instance index (0 = background)
        let labelMap = observation.instanceMask
        CVPixelBufferLockBaseAddress(labelMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labelMap, .readOnly) }

        let width = CVPixelBufferGetWidth(labelMap)
        let height = CVPixelBufferGetHeight(labelMap)
        guard let base = CVPixelBufferGetBaseAddress(labelMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(labelMap)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let cx = Int(point.x * CGFloat(width))
        let cy = Int(point.y * CGFloat(height))

#if DEBUG
        print("[Segmentation] Finding instance via labelMap (\(width)x\(height)) at (\(cx), \(cy)), tapDepth: \(tapDepth ?? -1)")
        print("[Segmentation] All instances: \(Array(allInstances))")
#endif

        // 1. Direct lookup at tap point
        if cx >= 0 && cx < width && cy >= 0 && cy < height {
            let label = Int(ptr[cy * bytesPerRow + cx])
            if label > 0 && allInstances.contains(label) {
#if DEBUG
                print("[Segmentation] Direct hit: instance \(label)")
#endif
                return label
            }
        }

        // 2. Search nearby area — collect proximity scores per instance
        let searchRadius = max(10, max(width, height) / 20)
        let step = max(1, searchRadius / 15)
        var instanceScores: [Int: Float] = [:]

        // Optionally collect depth samples per instance for penalty
        var depthLocked = false
        var depthWidth = 0, depthHeight = 0
        var depthPtr: UnsafeMutablePointer<Float32>?
        var depthStride = 0

        if let tapD = tapDepth, tapD > 0, let dm = depthMap {
            CVPixelBufferLockBaseAddress(dm, .readOnly)
            depthLocked = true
            depthWidth = CVPixelBufferGetWidth(dm)
            depthHeight = CVPixelBufferGetHeight(dm)
            if let db = CVPixelBufferGetBaseAddress(dm) {
                depthPtr = db.assumingMemoryBound(to: Float32.self)
                depthStride = CVPixelBufferGetBytesPerRow(dm) / MemoryLayout<Float32>.size
            }
        }
        defer {
            if depthLocked, let dm = depthMap {
                CVPixelBufferUnlockBaseAddress(dm, .readOnly)
            }
        }

        var instanceDepths: [Int: [Float]] = [:]

        for dy in Swift.stride(from: -searchRadius, through: searchRadius, by: step) {
            for dx in Swift.stride(from: -searchRadius, through: searchRadius, by: step) {
                let px = cx + dx
                let py = cy + dy
                guard px >= 0 && px < width && py >= 0 && py < height else { continue }

                let label = Int(ptr[py * bytesPerRow + px])
                guard label > 0 && allInstances.contains(label) else { continue }

                let dist = max(1, abs(dx) + abs(dy))
                instanceScores[label, default: 0] += Float(searchRadius) / Float(dist)

                // Sample depth for this pixel
                if let dPtr = depthPtr {
                    let dxp = Int(Float(px) * Float(depthWidth) / Float(width))
                    let dyp = Int(Float(py) * Float(depthHeight) / Float(height))
                    if dxp >= 0 && dxp < depthWidth && dyp >= 0 && dyp < depthHeight {
                        let d = dPtr[dyp * depthStride + dxp]
                        if d.isFinite && d > 0 {
                            instanceDepths[label, default: []].append(d)
                        }
                    }
                }
            }
        }

        // 3. Apply depth penalty if available
        if let tapD = tapDepth, tapD > 0 {
            for (label, depths) in instanceDepths where !depths.isEmpty {
                let sorted = depths.sorted()
                let median = sorted[sorted.count / 2]
                let relDiff = abs(median - tapD) / tapD
                let penalty = max(0.7, 1.0 - relDiff)
                instanceScores[label, default: 0] *= penalty
            }
        }

#if DEBUG
        for (label, score) in instanceScores.sorted(by: { $0.value > $1.value }) {
            print("[Segmentation] Instance \(label): score=\(score)")
        }
#endif

        guard let best = instanceScores.max(by: { $0.value < $1.value }) else {
#if DEBUG
            print("[Segmentation] No instance found within search radius")
#endif
            return nil
        }

#if DEBUG
        print("[Segmentation] Selected instance \(best.key) with score \(best.value)")
#endif
        return best.key
    }

    // MARK: - Depth Helpers

    /// Sample depth at a normalized point from an ARFrame's depth map
    static func sampleDepthFromFrame(at point: CGPoint, depthMap: CVPixelBuffer) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let ptr = base.assumingMemoryBound(to: Float32.self)
        let stride = bytesPerRow / MemoryLayout<Float32>.size

        let px = Int(point.x * CGFloat(width))
        let py = Int(point.y * CGFloat(height))
        guard px >= 0 && px < width && py >= 0 && py < height else { return nil }

        let depth = ptr[py * stride + px]
        return (depth.isFinite && depth > 0) ? depth : nil
    }

}

// MARK: - Mask Utilities

extension InstanceSegmentationService {
    /// Get the pixels that are part of the mask
    /// Note: The mask from generateMaskedImage is in the SAME coordinate system as the original image
    /// (regardless of the orientation parameter used for detection)
    func getMaskedPixels(
        mask: CVPixelBuffer,
        imageSize: CGSize,  // This is the original camera image size
        erode: Bool = false
    ) -> [(x: Int, y: Int)] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let pixelFormat = CVPixelBufferGetPixelFormatType(mask)

#if DEBUG
        print("[Segmentation] Mask size: \(maskWidth)x\(maskHeight)")
        print("[Segmentation] Mask pixel format: \(pixelFormat)")
        print("[Segmentation] Camera image size: \(imageSize)")
#endif

        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else {
#if DEBUG
            print("[Segmentation] No base address for mask")
#endif
            return []
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var pixels: [(x: Int, y: Int)] = []
        pixels.reserveCapacity(20000)  // Pre-allocate to reduce reallocations

        // The mask is in the same coordinate system as the original camera image
        // Just scale from mask resolution to image resolution
        let scaleX = imageSize.width / CGFloat(maskWidth)
        let scaleY = imageSize.height / CGFloat(maskHeight)

        // Sample every Nth pixel - balance between accuracy and memory
        let step = max(2, min(maskWidth, maskHeight) / 160)
        let maxPixels = 20000  // Limit total pixels to prevent memory issues

        // Determine bytes per pixel based on format
        // BGRA = 4 bytes per pixel, OneComponent8 = 1 byte per pixel
        let bytesPerPixel: Int
        if pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB {
            bytesPerPixel = 4
#if DEBUG
            print("[Segmentation] Using 4 bytes per pixel (BGRA/ARGB format)")
#endif
        } else {
            bytesPerPixel = 1
#if DEBUG
            print("[Segmentation] Using 1 byte per pixel")
#endif
        }

        // Helper to read mask value at a pixel coordinate
        func maskValue(atX mx: Int, atY my: Int) -> UInt8 {
            guard mx >= 0 && mx < maskWidth && my >= 0 && my < maskHeight else { return 0 }
            if bytesPerPixel == 4 {
                return buffer[my * bytesPerRow + mx * 4 + 3]
            } else {
                return buffer[my * bytesPerRow + mx]
            }
        }

        outerLoop: for y in Swift.stride(from: 0, to: maskHeight, by: step) {
            for x in Swift.stride(from: 0, to: maskWidth, by: step) {
                let pixelValue = maskValue(atX: x, atY: y)

                if pixelValue > 0 {
                    // Erosion: require all 4 cardinal neighbors (at step distance) to also be masked
                    if erode {
                        let up    = maskValue(atX: x, atY: y - step)
                        let down  = maskValue(atX: x, atY: y + step)
                        let left  = maskValue(atX: x - step, atY: y)
                        let right = maskValue(atX: x + step, atY: y)
                        if up == 0 || down == 0 || left == 0 || right == 0 {
                            continue
                        }
                    }

                    let imageX = Int(CGFloat(x) * scaleX)
                    let imageY = Int(CGFloat(y) * scaleY)
                    pixels.append((imageX, imageY))

                    // Limit pixels to prevent memory issues
                    if pixels.count >= maxPixels {
                        break outerLoop
                    }
                }
            }
        }

#if DEBUG
        print("[Segmentation] Found \(pixels.count) masked pixels")
#endif

        // Debug: print bounds of masked region
        if !pixels.isEmpty {
            let minX = pixels.map { $0.x }.min()!
            let maxX = pixels.map { $0.x }.max()!
            let minY = pixels.map { $0.y }.min()!
            let maxY = pixels.map { $0.y }.max()!
#if DEBUG
            print("[Segmentation] Mask bounds in image coords: x=\(minX)-\(maxX), y=\(minY)-\(maxY)")
            print("[Segmentation] Mask center: (\((minX+maxX)/2), \((minY+maxY)/2))")
            print("[Segmentation] Mask size: \(maxX-minX) x \(maxY-minY) pixels")
#endif

            // Also show as normalized coordinates for comparison with tap point
            let normalizedCenterX = Float(minX + maxX) / 2.0 / Float(imageSize.width)
            let normalizedCenterY = Float(minY + maxY) / 2.0 / Float(imageSize.height)
#if DEBUG
            print("[Segmentation] Mask center (normalized): (\(normalizedCenterX), \(normalizedCenterY))")
#endif
        }

        return pixels
    }

    /// Get the pixels that are part of the mask when ROI was used
    /// Handles both full-size masks and ROI-cropped masks
    /// - Parameters:
    ///   - mask: The mask pixel buffer
    ///   - imageSize: The original camera image size
    ///   - visionROI: The ROI in Vision normalized coordinates (0-1, bottom-left origin)
    func getMaskedPixelsWithROI(
        mask: CVPixelBuffer,
        imageSize: CGSize,
        visionROI: CGRect,
        erode: Bool = false
    ) -> [(x: Int, y: Int)] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let pixelFormat = CVPixelBufferGetPixelFormatType(mask)

#if DEBUG
        print("[Segmentation] Mask size: \(maskWidth)x\(maskHeight)")
        print("[Segmentation] Vision ROI: \(visionROI)")
        print("[Segmentation] Camera image size: \(imageSize)")
#endif

        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else {
#if DEBUG
            print("[Segmentation] No base address for mask")
#endif
            return []
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var pixels: [(x: Int, y: Int)] = []
        pixels.reserveCapacity(20000)

        // Determine bytes per pixel based on format
        let bytesPerPixel: Int
        if pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB {
            bytesPerPixel = 4
        } else {
            bytesPerPixel = 1
        }

        // Check if mask is full-size or ROI-cropped
        // Full-size: mask dimensions match image dimensions (within tolerance)
        let isFullSizeMask = abs(CGFloat(maskWidth) - imageSize.width) < 10 &&
                             abs(CGFloat(maskHeight) - imageSize.height) < 10
#if DEBUG
        print("[Segmentation] Mask is full-size: \(isFullSizeMask)")
#endif

        let step = max(2, min(maskWidth, maskHeight) / 160)
        let maxPixels = 20000

        // Helper to read mask value at a pixel coordinate
        func roiMaskValue(atX mx: Int, atY my: Int) -> UInt8 {
            guard mx >= 0 && mx < maskWidth && my >= 0 && my < maskHeight else { return 0 }
            if bytesPerPixel == 4 {
                return buffer[my * bytesPerRow + mx * 4 + 3]
            } else {
                return buffer[my * bytesPerRow + mx]
            }
        }

        outerLoop: for my in Swift.stride(from: 0, to: maskHeight, by: step) {
            for mx in Swift.stride(from: 0, to: maskWidth, by: step) {
                let pixelValue = roiMaskValue(atX: mx, atY: my)

                if pixelValue > 0 {
                    // Erosion: require all 4 cardinal neighbors to also be masked
                    if erode {
                        let up    = roiMaskValue(atX: mx, atY: my - step)
                        let down  = roiMaskValue(atX: mx, atY: my + step)
                        let left  = roiMaskValue(atX: mx - step, atY: my)
                        let right = roiMaskValue(atX: mx + step, atY: my)
                        if up == 0 || down == 0 || left == 0 || right == 0 {
                            continue
                        }
                    }
                    let imageX: Int
                    let imageY: Int

                    if isFullSizeMask {
                        // Full-size mask: mask coordinates directly correspond to image coordinates
                        // No ROI transformation needed
                        imageX = mx
                        imageY = my
                    } else {
                        // ROI-cropped mask: need to transform coordinates
                        // Mask coordinates to ROI-relative normalized (0-1)
                        let roiRelativeX = CGFloat(mx) / CGFloat(maskWidth)
                        let roiRelativeY = CGFloat(my) / CGFloat(maskHeight)

                        // ROI-relative to Vision absolute coordinates
                        // Vision uses bottom-left origin, mask uses top-left origin
                        // So we need to flip Y within the ROI
                        let visionX = visionROI.origin.x + roiRelativeX * visionROI.width
                        let visionY = visionROI.origin.y + (1.0 - roiRelativeY) * visionROI.height

                        // Vision coordinates (bottom-left origin) to image coordinates (top-left origin)
                        imageX = Int(visionX * imageSize.width)
                        imageY = Int((1.0 - visionY) * imageSize.height)
                    }

                    pixels.append((imageX, imageY))

                    if pixels.count >= maxPixels {
                        break outerLoop
                    }
                }
            }
        }

#if DEBUG
        print("[Segmentation] Found \(pixels.count) masked pixels")
#endif

        if !pixels.isEmpty {
            let minX = pixels.map { $0.x }.min()!
            let maxX = pixels.map { $0.x }.max()!
            let minY = pixels.map { $0.y }.min()!
            let maxY = pixels.map { $0.y }.max()!
#if DEBUG
            print("[Segmentation] Mask bounds in image coords: x=\(minX)-\(maxX), y=\(minY)-\(maxY)")
#endif
        }

        return pixels
    }

    /// Get mask coverage statistics
    func getMaskStats(mask: CVPixelBuffer) -> (totalPixels: Int, maskedPixels: Int) {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)

        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else {
            return (width * height, 0)
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var maskedCount = 0
        for y in 0..<height {
            for x in 0..<width {
                if buffer[y * bytesPerRow + x] > 0 {
                    maskedCount += 1
                }
            }
        }

        return (width * height, maskedCount)
    }
}
