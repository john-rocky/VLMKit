//
//  BoxEditingService.swift
//  SnapMeasure
//

import simd
import RealityKit
import CoreGraphics

/// Service for handling bounding box editing operations
class BoxEditingService {
    // MARK: - Types

    struct EditResult {
        var boundingBox: BoundingBox3D
        var didChange: Bool
    }

    // MARK: - Properties

    private let minimumExtent: Float = 0.01 // 1cm minimum dimension
    private let sensitivity: Float = 0.002  // Base sensitivity for drag

    // MARK: - Public Methods

    /// Convert 2D screen drag to 3D world movement
    /// - Parameters:
    ///   - screenDelta: The 2D screen drag delta
    ///   - cameraTransform: The camera's world transform
    ///   - distanceToObject: Distance from camera to the object
    /// - Returns: 3D world space delta
    func screenToWorldDelta(
        screenDelta: CGPoint,
        cameraTransform: simd_float4x4,
        distanceToObject: Float
    ) -> SIMD3<Float> {
        // Extract camera's local axes from transform
        let cameraRight = SIMD3<Float>(
            cameraTransform.columns.0.x,
            cameraTransform.columns.0.y,
            cameraTransform.columns.0.z
        )
        let cameraUp = SIMD3<Float>(
            cameraTransform.columns.1.x,
            cameraTransform.columns.1.y,
            cameraTransform.columns.1.z
        )

        // Scale sensitivity by distance (farther objects need more movement)
        let adjustedSensitivity = sensitivity * max(distanceToObject, 0.5)

        // Convert screen delta to world delta
        let worldDeltaX = cameraRight * Float(screenDelta.x) * adjustedSensitivity
        let worldDeltaY = cameraUp * Float(-screenDelta.y) * adjustedSensitivity // Invert Y

        return worldDeltaX + worldDeltaY
    }

    /// Apply corner handle drag to bounding box
    /// - Parameters:
    ///   - box: The current bounding box
    ///   - handleType: The corner handle being dragged
    ///   - worldDelta: The 3D world space movement
    /// - Returns: Updated bounding box
    func applyCornerDrag(
        box: BoundingBox3D,
        handleType: HandleType,
        worldDelta: SIMD3<Float>
    ) -> EditResult {
        guard handleType.isCorner,
              let cornerMultiplier = handleType.cornerMultiplier else {
            return EditResult(boundingBox: box, didChange: false)
        }

        // Convert world delta to local box space
        let localDelta = box.rotation.inverse.act(worldDelta)

        // Apply delta based on which corner is being dragged
        // The corner multiplier tells us which direction each axis should grow
        let scaledDelta = localDelta * cornerMultiplier

        // Calculate new extents and center offset
        var newExtents = box.extents
        var centerOffset = SIMD3<Float>.zero

        for axis in 0..<3 {
            let delta = scaledDelta[axis]

            // New extent is current extent plus half the delta
            // (because extents are half-sizes)
            let newExtent = newExtents[axis] + delta / 2

            if newExtent >= minimumExtent {
                // Center moves by half the delta in the direction of the corner
                centerOffset[axis] = (delta / 2) * cornerMultiplier[axis]
                newExtents[axis] = newExtent
            }
        }

        // Apply changes
        var newBox = box
        newBox.extents = newExtents
        newBox.center = box.center + box.rotation.act(centerOffset)

        return EditResult(boundingBox: newBox, didChange: true)
    }

    /// Apply face handle drag to bounding box
    /// - Parameters:
    ///   - box: The current bounding box
    ///   - handleType: The face handle being dragged
    ///   - screenDelta: The 2D screen space movement
    ///   - faceCenterScreenPos: The face center's position on screen
    ///   - boxCenterScreenPos: The box center's position on screen
    /// - Returns: Updated bounding box
    func applyFaceDrag(
        box: BoundingBox3D,
        handleType: HandleType,
        screenDelta: CGPoint,
        faceCenterScreenPos: CGPoint,
        boxCenterScreenPos: CGPoint
    ) -> EditResult {
        guard handleType.isFace,
              let axisIndex = handleType.axisIndex,
              let faceDirection = handleType.faceDirection else {
            return EditResult(boundingBox: box, didChange: false)
        }

        // Calculate "outward" direction on screen (from box center to face center)
        // This accurately represents the face normal direction on screen
        let outwardX = Float(faceCenterScreenPos.x - boxCenterScreenPos.x)
        let outwardY = Float(faceCenterScreenPos.y - boxCenterScreenPos.y)
        let outwardDir = SIMD2<Float>(outwardX, outwardY)
        let outwardLength = simd_length(outwardDir)

        // If handle is too close to center on screen, can't determine direction
        guard outwardLength > 5 else {
            return EditResult(boundingBox: box, didChange: false)
        }

        let normalizedOutward = outwardDir / outwardLength

        // Project screen delta onto the outward direction
        // Positive = dragging away from center (expand)
        // Negative = dragging toward center (contract)
        let screenDelta2D = SIMD2<Float>(Float(screenDelta.x), Float(screenDelta.y))
        let alignedDelta = simd_dot(screenDelta2D, normalizedOutward)

        // Calculate pixel-to-world conversion ratio
        // outwardLength (pixels) corresponds to extents[axisIndex] (meters)
        // So 1 pixel = extents[axisIndex] / outwardLength meters
        let pixelToWorld = box.extents[axisIndex] / outwardLength
        let scaledDelta = alignedDelta * pixelToWorld

        // Get the face normal in world space
        let axes = box.localAxes
        let faceNormal: SIMD3<Float>
        switch axisIndex {
        case 0: faceNormal = axes.x * faceDirection
        case 1: faceNormal = axes.y * faceDirection
        case 2: faceNormal = axes.z * faceDirection
        default: return EditResult(boundingBox: box, didChange: false)
        }

        // Calculate new extent
        var newExtents = box.extents
        let newExtent = newExtents[axisIndex] + scaledDelta / 2

        guard newExtent >= minimumExtent else {
            return EditResult(boundingBox: box, didChange: false)
        }

        newExtents[axisIndex] = newExtent

        // Center moves by half the delta along the face normal
        let centerOffset = faceNormal * (scaledDelta / 2)

        var newBox = box
        newBox.extents = newExtents
        newBox.center = box.center + centerOffset

        return EditResult(boundingBox: newBox, didChange: true)
    }

    /// Apply edge drag to bounding box
    /// - Parameters:
    ///   - box: The current bounding box
    ///   - edgeIndex: The index of the edge being dragged (0-11)
    ///   - worldDelta: The 3D world space movement
    /// - Returns: Updated bounding box
    func applyEdgeDrag(
        box: BoundingBox3D,
        edgeIndex: Int,
        worldDelta: SIMD3<Float>
    ) -> EditResult {
        guard edgeIndex >= 0 && edgeIndex < 12 else {
            return EditResult(boundingBox: box, didChange: false)
        }

        // Convert world delta to local box space
        let localDelta = box.rotation.inverse.act(worldDelta)

        // Get edge info to determine which face to move
        let edgeInfo = getEdgeInfo(edgeIndex: edgeIndex)

        var newBox = box
        var didChange = false

        // Move the face that this edge belongs to
        // The edge's primary axis determines which face normal to use
        let axes = box.localAxes

        // Determine which axis to affect based on edge orientation
        // and project the delta onto the face normal
        for (axisIndex, direction) in edgeInfo.affectedFaces {
            let faceNormal: SIMD3<Float>
            switch axisIndex {
            case 0: faceNormal = axes.x * direction
            case 1: faceNormal = axes.y * direction
            case 2: faceNormal = axes.z * direction
            default: continue
            }

            // Project world delta onto face normal
            let projectedDelta = simd_dot(worldDelta, faceNormal)

            // Only apply if the drag is somewhat in the direction of the face
            guard abs(projectedDelta) > 0.0001 else { continue }

            // Calculate new extent
            let newExtent = newBox.extents[axisIndex] + projectedDelta / 2

            if newExtent >= minimumExtent {
                newBox.extents[axisIndex] = newExtent
                // Center moves by half the projected delta along the face normal
                newBox.center = newBox.center + faceNormal * (projectedDelta / 2)
                didChange = true
            }
        }

        return EditResult(boundingBox: newBox, didChange: didChange)
    }

    /// Get information about which faces an edge affects
    private func getEdgeInfo(edgeIndex: Int) -> (affectedFaces: [(axisIndex: Int, direction: Float)], edgeAxis: Int) {
        // Edge indices from BoundingBox3D.edgeIndices:
        // Bottom face edges (Z = -1):
        // 0: corners (0,1) - along X axis, at Y=-1, Z=-1 -> affects -Y and -Z faces
        // 1: corners (1,2) - along Y axis, at X=+1, Z=-1 -> affects +X and -Z faces
        // 2: corners (2,3) - along X axis, at Y=+1, Z=-1 -> affects +Y and -Z faces
        // 3: corners (3,0) - along Y axis, at X=-1, Z=-1 -> affects -X and -Z faces
        //
        // Top face edges (Z = +1):
        // 4: corners (4,5) - along X axis, at Y=-1, Z=+1 -> affects -Y and +Z faces
        // 5: corners (5,6) - along Y axis, at X=+1, Z=+1 -> affects +X and +Z faces
        // 6: corners (6,7) - along X axis, at Y=+1, Z=+1 -> affects +Y and +Z faces
        // 7: corners (7,4) - along Y axis, at X=-1, Z=+1 -> affects -X and +Z faces
        //
        // Vertical edges (along Z axis):
        // 8: corners (0,4) - at X=-1, Y=-1 -> affects -X and -Y faces
        // 9: corners (1,5) - at X=+1, Y=-1 -> affects +X and -Y faces
        // 10: corners (2,6) - at X=+1, Y=+1 -> affects +X and +Y faces
        // 11: corners (3,7) - at X=-1, Y=+1 -> affects -X and +Y faces

        switch edgeIndex {
        case 0:  return ([(1, -1), (2, -1)], 0)  // -Y, -Z
        case 1:  return ([(0, +1), (2, -1)], 1)  // +X, -Z
        case 2:  return ([(1, +1), (2, -1)], 0)  // +Y, -Z
        case 3:  return ([(0, -1), (2, -1)], 1)  // -X, -Z
        case 4:  return ([(1, -1), (2, +1)], 0)  // -Y, +Z
        case 5:  return ([(0, +1), (2, +1)], 1)  // +X, +Z
        case 6:  return ([(1, +1), (2, +1)], 0)  // +Y, +Z
        case 7:  return ([(0, -1), (2, +1)], 1)  // -X, +Z
        case 8:  return ([(0, -1), (1, -1)], 2)  // -X, -Y
        case 9:  return ([(0, +1), (1, -1)], 2)  // +X, -Y
        case 10: return ([(0, +1), (1, +1)], 2)  // +X, +Y
        case 11: return ([(0, -1), (1, +1)], 2)  // -X, +Y
        default: return ([], 0)
        }
    }

    /// Fit bounding box to points within current box
    /// - Parameters:
    ///   - currentBox: The current bounding box
    ///   - allPoints: All available point cloud points
    ///   - mode: Measurement mode for PCA orientation
    /// - Returns: New fitted bounding box, or nil if not enough points
    func fitToPoints(
        currentBox: BoundingBox3D,
        allPoints: [SIMD3<Float>],
        mode: MeasurementMode
    ) -> BoundingBox3D? {
        // Filter points that are inside the current box
        let pointsInBox = allPoints.filter { currentBox.contains($0) }

        guard pointsInBox.count >= 10 else {
#if DEBUG
            print("[BoxEditingService] Not enough points in box: \(pointsInBox.count)")
#endif
            return nil
        }

#if DEBUG
        print("[BoxEditingService] Fitting to \(pointsInBox.count) points")
#endif

        // Use BoundingBoxEstimator to compute new OBB
        let estimator = BoundingBoxEstimator()
        return estimator.estimateBoundingBox(points: pointsInBox, mode: mode)
    }
}

// MARK: - SIMD3 Extension for subscript access

private extension SIMD3 where Scalar == Float {
    subscript(index: Int) -> Float {
        get {
            switch index {
            case 0: return x
            case 1: return y
            case 2: return z
            default: return 0
            }
        }
        set {
            switch index {
            case 0: x = newValue
            case 1: y = newValue
            case 2: z = newValue
            default: break
            }
        }
    }
}
