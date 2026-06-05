//
//  DebugVisualization.swift
//  SnapMeasure
//

#if DEBUG

import UIKit
import ARKit
import RealityKit
import simd

/// Debug visualization utilities for troubleshooting measurement issues
class DebugVisualization {

    // MARK: - Mask Visualization

    /// Create a debug image showing the segmentation mask overlaid on the camera image
    /// Both camera image and mask are in landscape orientation (same coordinate system)
    /// We rotate to portrait for proper viewing on screen
    static func visualizeMask(
        mask: CVPixelBuffer,
        cameraImage: CVPixelBuffer,
        tapPoint: CGPoint? = nil
    ) -> UIImage? {
        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let imageWidth = CVPixelBufferGetWidth(cameraImage)
        let imageHeight = CVPixelBufferGetHeight(cameraImage)

        print("[DebugViz] Mask size: \(maskWidth)x\(maskHeight)")
        print("[DebugViz] Camera image size: \(imageWidth)x\(imageHeight)")

        // Create UIImage from camera with proper orientation
        let ciImage = CIImage(cvPixelBuffer: cameraImage)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        // Use reduced resolution to save memory (1/4 size)
        let scale: CGFloat = 0.25
        let drawWidth = CGFloat(imageWidth) * scale
        let drawHeight = CGFloat(imageHeight) * scale
        let landscapeSize = CGSize(width: drawWidth, height: drawHeight)

        UIGraphicsBeginImageContextWithOptions(landscapeSize, false, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

        // Draw camera image - need to flip because CGContext has flipped Y
        ctx.saveGState()
        ctx.translateBy(x: 0, y: drawHeight)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight))
        ctx.restoreGState()

        // Read and overlay mask (mask is in same landscape coordinates as camera)
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        guard let maskBase = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let maskBytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let maskPtr = maskBase.assumingMemoryBound(to: UInt8.self)

        // Scale from mask to draw coordinates
        let scaleX = drawWidth / CGFloat(maskWidth)
        let scaleY = drawHeight / CGFloat(maskHeight)

        // Draw mask overlay - sample every few pixels for performance
        ctx.setFillColor(UIColor.green.withAlphaComponent(0.4).cgColor)

        // Determine bytes per pixel based on format
        let maskPixelFormat = CVPixelBufferGetPixelFormatType(mask)
        let bytesPerPixel: Int
        if maskPixelFormat == kCVPixelFormatType_32BGRA || maskPixelFormat == kCVPixelFormatType_32ARGB {
            bytesPerPixel = 4
        } else {
            bytesPerPixel = 1
        }

        var maskedPixelCount = 0
        let sampleStep = max(4, min(maskWidth, maskHeight) / 100)  // Larger step for memory efficiency
        for my in Swift.stride(from: 0, to: maskHeight, by: sampleStep) {
            for mx in Swift.stride(from: 0, to: maskWidth, by: sampleStep) {
                let pixelOffset = my * maskBytesPerRow + mx * bytesPerPixel
                let value: UInt8
                if bytesPerPixel == 4 {
                    value = maskPtr[pixelOffset + 3]  // Alpha channel
                } else {
                    value = maskPtr[pixelOffset]
                }

                if value > 0 {
                    maskedPixelCount += 1
                    let rect = CGRect(
                        x: CGFloat(mx) * scaleX,
                        y: CGFloat(my) * scaleY,
                        width: scaleX * CGFloat(sampleStep),
                        height: scaleY * CGFloat(sampleStep)
                    )
                    ctx.fill(rect)
                }
            }
        }

        print("[DebugViz] Masked pixels sampled: \(maskedPixelCount)")

        // Draw tap point if provided (in landscape normalized coordinates)
        if let tap = tapPoint {
            let tapX = tap.x * drawWidth
            let tapY = tap.y * drawHeight
            let markerSize: CGFloat = 10 * scale

            ctx.setFillColor(UIColor.red.cgColor)
            ctx.fillEllipse(in: CGRect(x: tapX - markerSize, y: tapY - markerSize, width: markerSize * 2, height: markerSize * 2))

            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: tapX - markerSize, y: tapY - markerSize, width: markerSize * 2, height: markerSize * 2))
        }

        guard let landscapeImage = UIGraphicsGetImageFromCurrentImageContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        UIGraphicsEndImageContext()

        // Rotate the landscape image to portrait for display
        let portraitSize = CGSize(width: drawHeight, height: drawWidth)
        UIGraphicsBeginImageContextWithOptions(portraitSize, false, 1.0)
        guard let portraitCtx = UIGraphicsGetCurrentContext() else { return nil }

        portraitCtx.translateBy(x: portraitSize.width / 2, y: portraitSize.height / 2)
        portraitCtx.rotate(by: .pi / 2)
        portraitCtx.translateBy(x: -landscapeSize.width / 2, y: -landscapeSize.height / 2)

        landscapeImage.draw(in: CGRect(origin: .zero, size: landscapeSize))

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return result
    }

    /// Create a debug image showing the segmentation mask with ROI
    /// The mask covers only the ROI area, so we need to position it correctly on the camera image
    /// - Parameters:
    ///   - mask: Segmentation mask pixel buffer
    ///   - cameraImage: Camera image pixel buffer
    ///   - visionROI: ROI in Vision normalized coordinates (0-1, bottom-left origin)
    ///   - screenRect: Original screen rectangle that was used to create the ROI
    ///   - viewSize: Size of the view (screen) for coordinate conversion
    ///   - tapPoint: Optional tap point in normalized image coordinates
    static func visualizeMaskWithROI(
        mask: CVPixelBuffer,
        cameraImage: CVPixelBuffer,
        visionROI: CGRect,
        screenRect: CGRect,
        viewSize: CGSize,
        tapPoint: CGPoint? = nil
    ) -> UIImage? {
        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let imageWidth = CVPixelBufferGetWidth(cameraImage)
        let imageHeight = CVPixelBufferGetHeight(cameraImage)

        print("[DebugViz] Mask size: \(maskWidth)x\(maskHeight)")
        print("[DebugViz] Camera image size: \(imageWidth)x\(imageHeight)")
        print("[DebugViz] Vision ROI: \(visionROI)")

        // Create UIImage from camera with proper orientation
        let ciImage = CIImage(cvPixelBuffer: cameraImage)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        // Use reduced resolution to save memory (1/4 size)
        let scale: CGFloat = 0.25
        let drawWidth = CGFloat(imageWidth) * scale
        let drawHeight = CGFloat(imageHeight) * scale
        let landscapeSize = CGSize(width: drawWidth, height: drawHeight)

        UIGraphicsBeginImageContextWithOptions(landscapeSize, false, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

        // Draw camera image - need to flip because CGContext has flipped Y
        ctx.saveGState()
        ctx.translateBy(x: 0, y: drawHeight)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight))
        ctx.restoreGState()

        // Read mask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        guard let maskBase = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let maskBytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let maskPtr = maskBase.assumingMemoryBound(to: UInt8.self)

        // Determine bytes per pixel based on format
        let maskPixelFormat = CVPixelBufferGetPixelFormatType(mask)
        let bytesPerPixel: Int
        if maskPixelFormat == kCVPixelFormatType_32BGRA || maskPixelFormat == kCVPixelFormatType_32ARGB {
            bytesPerPixel = 4
        } else {
            bytesPerPixel = 1
        }

        // Draw mask overlay - positioned according to ROI
        // Vision ROI is in normalized coordinates (0-1, bottom-left origin)
        // Need to convert to draw coordinates (top-left origin)
        ctx.setFillColor(UIColor.green.withAlphaComponent(0.4).cgColor)

        // Check if mask is full-size or ROI-cropped
        let isFullSizeMask = abs(maskWidth - imageWidth) < 10 && abs(maskHeight - imageHeight) < 10
        print("[DebugViz] Mask is full-size: \(isFullSizeMask)")

        var maskedPixelCount = 0
        let sampleStep = max(4, min(maskWidth, maskHeight) / 100)

        // Scale factors for direct mask-to-draw conversion (full-size mask)
        let scaleX = drawWidth / CGFloat(maskWidth)
        let scaleY = drawHeight / CGFloat(maskHeight)

        for my in Swift.stride(from: 0, to: maskHeight, by: sampleStep) {
            for mx in Swift.stride(from: 0, to: maskWidth, by: sampleStep) {
                let pixelOffset = my * maskBytesPerRow + mx * bytesPerPixel
                let value: UInt8
                if bytesPerPixel == 4 {
                    value = maskPtr[pixelOffset + 3]
                } else {
                    value = maskPtr[pixelOffset]
                }

                if value > 0 {
                    maskedPixelCount += 1

                    let drawX: CGFloat
                    let drawY: CGFloat
                    let stepWidth: CGFloat
                    let stepHeight: CGFloat

                    if isFullSizeMask {
                        // Full-size mask: direct scaling from mask to draw coordinates
                        drawX = CGFloat(mx) * scaleX
                        drawY = CGFloat(my) * scaleY
                        stepWidth = CGFloat(sampleStep) * scaleX
                        stepHeight = CGFloat(sampleStep) * scaleY
                    } else {
                        // ROI-cropped mask: transform through Vision coordinates
                        // Mask coords to ROI-relative normalized (0-1)
                        let roiRelativeX = CGFloat(mx) / CGFloat(maskWidth)
                        let roiRelativeY = CGFloat(my) / CGFloat(maskHeight)

                        // ROI-relative to Vision absolute (bottom-left origin)
                        // Flip Y within ROI because mask uses top-left origin
                        let visionX = visionROI.origin.x + roiRelativeX * visionROI.width
                        let visionY = visionROI.origin.y + (1.0 - roiRelativeY) * visionROI.height

                        // Vision coords to draw coords (top-left origin)
                        drawX = visionX * drawWidth
                        drawY = (1.0 - visionY) * drawHeight

                        // Calculate step size separately for width and height
                        stepWidth = CGFloat(sampleStep) / CGFloat(maskWidth) * visionROI.width * drawWidth
                        stepHeight = CGFloat(sampleStep) / CGFloat(maskHeight) * visionROI.height * drawHeight
                    }

                    ctx.fill(CGRect(x: drawX, y: drawY, width: stepWidth, height: stepHeight))
                }
            }
        }

        print("[DebugViz] Masked pixels sampled: \(maskedPixelCount)")

        // Draw ROI rectangle outline
        // We need to draw the ROI in a way that visually matches the screen box
        // after the portrait rotation is applied.
        //
        // The key insight: the debug image will be rotated 90° CCW after drawing.
        // To make the ROI box match the screen box aspect ratio, we need to account
        // for the different aspect ratios between screen and camera image.
        //
        // Screen: portrait (width < height), e.g., 390×844
        // Camera: landscape (width > height), e.g., 1920×1440
        // Debug image: landscape draw → portrait display
        //
        // ARView displays camera with aspect fill, cropping the wider dimension.
        // Camera aspect: 1920/1440 = 1.33 (landscape)
        // Screen aspect: 390/844 = 0.46 (portrait)
        // After 90° rotation, camera becomes portrait: 1440/1920 = 0.75
        // Since 0.75 > 0.46, camera is wider than screen when displayed
        // This means horizontal cropping occurs on the camera image

        ctx.setStrokeColor(UIColor.yellow.cgColor)
        ctx.setLineWidth(2)

        // Calculate the visible area of camera image on screen (aspect fill)
        // Camera rotated to portrait: cameraPortraitW = imageHeight, cameraPortraitH = imageWidth
        let cameraPortraitW = CGFloat(imageHeight)
        let cameraPortraitH = CGFloat(imageWidth)
        let cameraAspect = cameraPortraitW / cameraPortraitH  // e.g., 1440/1920 = 0.75
        let screenAspect = viewSize.width / viewSize.height   // e.g., 390/844 = 0.46

        // With aspect fill, fit the narrower dimension and crop the wider
        let visibleCameraW: CGFloat
        let visibleCameraH: CGFloat
        let cropOffsetX: CGFloat
        let cropOffsetY: CGFloat

        if cameraAspect > screenAspect {
            // Camera is wider → crop horizontally
            // Screen height maps to full camera height, screen width maps to partial camera width
            visibleCameraH = cameraPortraitH  // Full height visible
            visibleCameraW = cameraPortraitH * screenAspect  // Only this width is visible
            cropOffsetX = (cameraPortraitW - visibleCameraW) / 2
            cropOffsetY = 0
        } else {
            // Camera is taller → crop vertically
            visibleCameraW = cameraPortraitW
            visibleCameraH = cameraPortraitW / screenAspect
            cropOffsetX = 0
            cropOffsetY = (cameraPortraitH - visibleCameraH) / 2
        }

        print("[DebugViz] Camera portrait size: \(cameraPortraitW)×\(cameraPortraitH)")
        print("[DebugViz] Visible camera area: \(visibleCameraW)×\(visibleCameraH)")
        print("[DebugViz] Crop offset: (\(cropOffsetX), \(cropOffsetY))")

        // Convert screen rect to camera portrait coordinates (accounting for crop)
        // Screen (0,0) maps to camera (cropOffsetX, cropOffsetY)
        // Screen (viewSize.width, viewSize.height) maps to camera (cropOffsetX + visibleCameraW, cropOffsetY + visibleCameraH)
        let screenToCameraScaleX = visibleCameraW / viewSize.width
        let screenToCameraScaleY = visibleCameraH / viewSize.height

        let cameraPortraitX = screenRect.minX * screenToCameraScaleX + cropOffsetX
        let cameraPortraitY = screenRect.minY * screenToCameraScaleY + cropOffsetY
        let cameraPortraitRectW = screenRect.width * screenToCameraScaleX
        let cameraPortraitRectH = screenRect.height * screenToCameraScaleY

        // Camera portrait coords → Camera landscape coords (reverse of 90° CCW rotation)
        // Portrait (px, py) → Landscape (py, cameraPortraitW - px)
        // For rectangle top-left corner and size:
        let cameraLandscapeX = cameraPortraitY
        let cameraLandscapeY = cameraPortraitW - cameraPortraitX - cameraPortraitRectW
        let cameraLandscapeW = cameraPortraitRectH
        let cameraLandscapeH = cameraPortraitRectW

        // Camera landscape coords to draw coords (scale down)
        let cameraToDrawScaleX = drawWidth / CGFloat(imageWidth)
        let cameraToDrawScaleY = drawHeight / CGFloat(imageHeight)

        let roiDrawX = cameraLandscapeX * cameraToDrawScaleX
        let roiDrawY = cameraLandscapeY * cameraToDrawScaleY
        let roiDrawW = cameraLandscapeW * cameraToDrawScaleX
        let roiDrawH = cameraLandscapeH * cameraToDrawScaleY

        print("[DebugViz] Screen rect: \(screenRect), View size: \(viewSize)")
        print("[DebugViz] ROI draw rect: x=\(roiDrawX), y=\(roiDrawY), w=\(roiDrawW), h=\(roiDrawH)")

        ctx.stroke(CGRect(x: roiDrawX, y: roiDrawY, width: roiDrawW, height: roiDrawH))

        // Draw tap point if provided (in landscape normalized coordinates)
        if let tap = tapPoint {
            let tapX = tap.x * drawWidth
            let tapY = tap.y * drawHeight
            let markerSize: CGFloat = 10 * scale

            ctx.setFillColor(UIColor.red.cgColor)
            ctx.fillEllipse(in: CGRect(x: tapX - markerSize, y: tapY - markerSize, width: markerSize * 2, height: markerSize * 2))

            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: tapX - markerSize, y: tapY - markerSize, width: markerSize * 2, height: markerSize * 2))
        }

        guard let landscapeImage = UIGraphicsGetImageFromCurrentImageContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        UIGraphicsEndImageContext()

        // Rotate the landscape image to portrait for display
        let portraitSize = CGSize(width: drawHeight, height: drawWidth)
        UIGraphicsBeginImageContextWithOptions(portraitSize, false, 1.0)
        guard let portraitCtx = UIGraphicsGetCurrentContext() else { return nil }

        portraitCtx.translateBy(x: portraitSize.width / 2, y: portraitSize.height / 2)
        portraitCtx.rotate(by: .pi / 2)
        portraitCtx.translateBy(x: -landscapeSize.width / 2, y: -landscapeSize.height / 2)

        landscapeImage.draw(in: CGRect(origin: .zero, size: landscapeSize))

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return result
    }

    // MARK: - Point Cloud Visualization

    /// Create RealityKit entities for visualizing point cloud
    static func createPointCloudEntity(
        points: [SIMD3<Float>],
        color: UIColor = .cyan,
        pointSize: Float = 0.005
    ) -> Entity {
        let parentEntity = Entity()

        // Limit points for performance - reduce to 100 max to save memory
        let maxPoints = min(points.count, 100)
        let stepSize = max(1, points.count / maxPoints)

        print("[DebugViz] Creating point cloud with \(maxPoints) points (step: \(stepSize))")

        var material = SimpleMaterial()
        material.color = .init(tint: color)

        let sphereMesh = MeshResource.generateSphere(radius: pointSize)

        for i in Swift.stride(from: 0, to: points.count, by: stepSize) {
            let point = points[i]
            let pointEntity = ModelEntity(mesh: sphereMesh, materials: [material])
            pointEntity.position = point
            parentEntity.addChild(pointEntity)
        }

        // Add centroid marker (larger, different color)
        if !points.isEmpty {
            let centroid = points.reduce(.zero, +) / Float(points.count)
            var centroidMaterial = SimpleMaterial()
            centroidMaterial.color = .init(tint: .red)
            let centroidEntity = ModelEntity(
                mesh: MeshResource.generateSphere(radius: pointSize * 3),
                materials: [centroidMaterial]
            )
            centroidEntity.position = centroid
            parentEntity.addChild(centroidEntity)

            print("[DebugViz] Point cloud centroid: \(centroid)")
        }

        return parentEntity
    }

    // MARK: - Depth Map Visualization

    /// Create a debug image showing depth values
    /// Depth map is in landscape, we rotate to portrait for display
    static func visualizeDepthMap(
        depthMap: CVPixelBuffer,
        maskedPixels: [(x: Int, y: Int)]? = nil,
        imageSize: CGSize
    ) -> UIImage? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPtr = baseAddress.assumingMemoryBound(to: Float32.self)

        // Sample to find min/max depth
        var minDepth: Float = .infinity
        var maxDepth: Float = 0
        let sampleStep = 4

        for y in Swift.stride(from: 0, to: height, by: sampleStep) {
            for x in Swift.stride(from: 0, to: width, by: sampleStep) {
                let index = y * (bytesPerRow / MemoryLayout<Float32>.size) + x
                let depth = depthPtr[index]
                if depth.isFinite && depth > 0 {
                    minDepth = min(minDepth, depth)
                    maxDepth = max(maxDepth, depth)
                }
            }
        }

        print("[DebugViz] Depth map size: \(width)x\(height)")
        print("[DebugViz] Depth range: \(minDepth)m - \(maxDepth)m")

        // Use reduced resolution
        let scale: CGFloat = 0.5
        let drawWidth = CGFloat(width) * scale
        let drawHeight = CGFloat(height) * scale
        let landscapeSize = CGSize(width: drawWidth, height: drawHeight)

        UIGraphicsBeginImageContextWithOptions(landscapeSize, false, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

        // Draw depth as grayscale with sampling
        let drawStep = 2
        for dy in Swift.stride(from: 0, to: Int(drawHeight), by: drawStep) {
            for dx in Swift.stride(from: 0, to: Int(drawWidth), by: drawStep) {
                let x = Int(CGFloat(dx) / scale)
                let y = Int(CGFloat(dy) / scale)
                guard x < width && y < height else { continue }

                let index = y * (bytesPerRow / MemoryLayout<Float32>.size) + x
                let depth = depthPtr[index]

                var brightness: CGFloat = 0
                if depth.isFinite && depth > 0 && maxDepth > minDepth {
                    brightness = CGFloat(1.0 - (depth - minDepth) / (maxDepth - minDepth))
                }

                ctx.setFillColor(UIColor(white: brightness, alpha: 1.0).cgColor)
                ctx.fill(CGRect(x: dx, y: dy, width: drawStep, height: drawStep))
            }
        }

        // Overlay masked pixels if provided
        if let pixels = maskedPixels {
            let scaleToDepth = CGFloat(width) / imageSize.width
            let scaleToDraw = scale

            ctx.setFillColor(UIColor.green.withAlphaComponent(0.6).cgColor)

            // Sample masked pixels for performance
            let pixelStep = max(1, pixels.count / 500)
            for i in Swift.stride(from: 0, to: pixels.count, by: pixelStep) {
                let pixel = pixels[i]
                let depthX = CGFloat(pixel.x) * scaleToDepth * scaleToDraw
                let depthY = CGFloat(pixel.y) * scaleToDepth * scaleToDraw
                ctx.fill(CGRect(x: depthX - 1, y: depthY - 1, width: 3, height: 3))
            }
        }

        guard let landscapeImage = UIGraphicsGetImageFromCurrentImageContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        UIGraphicsEndImageContext()

        // Rotate to portrait for display
        let portraitSize = CGSize(width: drawHeight, height: drawWidth)
        UIGraphicsBeginImageContextWithOptions(portraitSize, false, 1.0)
        guard let portraitCtx = UIGraphicsGetCurrentContext() else { return nil }

        portraitCtx.translateBy(x: portraitSize.width / 2, y: portraitSize.height / 2)
        portraitCtx.rotate(by: .pi / 2)
        portraitCtx.translateBy(x: -landscapeSize.width / 2, y: -landscapeSize.height / 2)

        landscapeImage.draw(in: CGRect(origin: .zero, size: landscapeSize))

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return result
    }

    // MARK: - Coordinate System Visualization

    /// Create axes at the camera position
    static func createAxesEntity(at transform: simd_float4x4, length: Float = 0.1) -> Entity {
        let parentEntity = Entity()

        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        // X axis - Red
        let xAxis = createLineEntity(
            from: position,
            to: position + SIMD3<Float>(length, 0, 0),
            color: .red
        )
        parentEntity.addChild(xAxis)

        // Y axis - Green
        let yAxis = createLineEntity(
            from: position,
            to: position + SIMD3<Float>(0, length, 0),
            color: .green
        )
        parentEntity.addChild(yAxis)

        // Z axis - Blue
        let zAxis = createLineEntity(
            from: position,
            to: position + SIMD3<Float>(0, 0, length),
            color: .blue
        )
        parentEntity.addChild(zAxis)

        print("[DebugViz] Created axes at position: \(position)")

        return parentEntity
    }

    private static func createLineEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, color: UIColor) -> Entity {
        let direction = end - start
        let length = simd_length(direction)

        let mesh = MeshResource.generateBox(size: [0.003, 0.003, length])
        var material = SimpleMaterial()
        material.color = .init(tint: color)

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = (start + end) / 2

        // Orient along the line
        let defaultDir = SIMD3<Float>(0, 0, 1)
        let normalizedDir = simd_normalize(direction)

        if simd_length(normalizedDir - defaultDir) > 0.001 && simd_length(normalizedDir + defaultDir) > 0.001 {
            let axis = simd_cross(defaultDir, normalizedDir)
            let axisLen = simd_length(axis)
            if axisLen > 0.001 {
                let angle = acos(simd_clamp(simd_dot(defaultDir, normalizedDir), -1, 1))
                entity.orientation = simd_quatf(angle: angle, axis: axis / axisLen)
            }
        }

        return entity
    }

    // MARK: - Tap Point 3D Visualization

    /// Create a marker at the raycast hit point
    static func createTapMarker(at position: SIMD3<Float>) -> Entity {
        var material = SimpleMaterial()
        material.color = .init(tint: .yellow)

        let entity = ModelEntity(
            mesh: MeshResource.generateSphere(radius: 0.02),
            materials: [material]
        )
        entity.position = position

        print("[DebugViz] Created tap marker at: \(position)")

        return entity
    }
}

// MARK: - Debug Image View

import SwiftUI

struct DebugImageView: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()

                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Debug View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Debug Mask Compare View (Side-by-Side)

struct DebugMaskCompareView: View {
    let image1: UIImage
    let image2: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                if let image2 = image2 {
                    // Two-tap: show both masks side by side
                    HStack(spacing: 8) {
                        VStack(spacing: 4) {
                            Text("Tap 1")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Image(uiImage: image1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }
                        VStack(spacing: 4) {
                            Text("Tap 2")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Image(uiImage: image2)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }
                    }
                    .padding()
                } else {
                    // Single tap or box selection: show one image
                    Image(uiImage: image1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                }

                Text("Segmentation Mask (Green) + Tap Point (Red)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Mask Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
