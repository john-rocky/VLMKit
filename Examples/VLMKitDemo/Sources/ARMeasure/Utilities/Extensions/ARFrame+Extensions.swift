//
//  ARFrame+Extensions.swift
//  SnapMeasure
//

import ARKit
import CoreImage
import CoreVideo
import UIKit

extension ARFrame {
    /// Render the AR camera frame as an upright (portrait) `UIImage`. ARKit's
    /// `capturedImage` is in landscape sensor orientation; rotate 90° CW to
    /// match how the user sees the scene on a portrait-held device.
    func capturedUIImage() -> UIImage? {
        let ci = CIImage(cvPixelBuffer: capturedImage).oriented(.right)
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension ARFrame {
    /// Get the depth value at a specific pixel location (in depth map coordinates)
    func depthValue(at point: CGPoint) -> Float? {
        guard let depthMap = sceneDepth?.depthMap ?? smoothedSceneDepth?.depthMap else {
            return nil
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        let x = Int(point.x)
        let y = Int(point.y)

        guard x >= 0 && x < width && y >= 0 && y < height else {
            return nil
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)

        let index = y * (bytesPerRow / MemoryLayout<Float32>.size) + x
        let depth = floatBuffer[index]

        return depth.isFinite && depth > 0 ? depth : nil
    }

    /// Get the confidence value at a specific pixel location
    func confidenceValue(at point: CGPoint) -> ARConfidenceLevel? {
        guard let confidenceMap = sceneDepth?.confidenceMap ?? smoothedSceneDepth?.confidenceMap else {
            return nil
        }

        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }

        let width = CVPixelBufferGetWidth(confidenceMap)
        let height = CVPixelBufferGetHeight(confidenceMap)

        let x = Int(point.x)
        let y = Int(point.y)

        guard x >= 0 && x < width && y >= 0 && y < height else {
            return nil
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        let index = y * bytesPerRow + x
        let value = buffer[index]

        return ARConfidenceLevel(rawValue: Int(value))
    }

    /// Get the size of the depth map
    var depthMapSize: CGSize? {
        guard let depthMap = sceneDepth?.depthMap ?? smoothedSceneDepth?.depthMap else {
            return nil
        }
        return CGSize(
            width: CVPixelBufferGetWidth(depthMap),
            height: CVPixelBufferGetHeight(depthMap)
        )
    }

    /// Get the size of the captured image
    var capturedImageSize: CGSize {
        CGSize(
            width: CVPixelBufferGetWidth(capturedImage),
            height: CVPixelBufferGetHeight(capturedImage)
        )
    }

    /// Convert a point from captured image coordinates to depth map coordinates
    func convertToDepthCoordinates(_ point: CGPoint) -> CGPoint? {
        guard let depthSize = depthMapSize else { return nil }
        let imageSize = capturedImageSize

        return CGPoint(
            x: point.x * depthSize.width / imageSize.width,
            y: point.y * depthSize.height / imageSize.height
        )
    }

    /// Convert a point from screen coordinates to captured image coordinates
    func convertScreenToImageCoordinates(_ screenPoint: CGPoint, viewSize: CGSize, orientation: UIInterfaceOrientation) -> CGPoint {
        let imageSize = capturedImageSize

        // The camera image is in landscape right orientation
        // We need to convert based on the current interface orientation
        switch orientation {
        case .portrait:
            return CGPoint(
                x: screenPoint.y / viewSize.height * imageSize.width,
                y: (1 - screenPoint.x / viewSize.width) * imageSize.height
            )
        case .portraitUpsideDown:
            return CGPoint(
                x: (1 - screenPoint.y / viewSize.height) * imageSize.width,
                y: screenPoint.x / viewSize.width * imageSize.height
            )
        case .landscapeLeft:
            return CGPoint(
                x: (1 - screenPoint.x / viewSize.width) * imageSize.width,
                y: (1 - screenPoint.y / viewSize.height) * imageSize.height
            )
        case .landscapeRight, .unknown:
            return CGPoint(
                x: screenPoint.x / viewSize.width * imageSize.width,
                y: screenPoint.y / viewSize.height * imageSize.height
            )
        @unknown default:
            return CGPoint(
                x: screenPoint.x / viewSize.width * imageSize.width,
                y: screenPoint.y / viewSize.height * imageSize.height
            )
        }
    }
}
