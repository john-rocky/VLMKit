//
//  BoundingBox3D.swift
//  SnapMeasure
//

import Foundation
import simd

/// Represents an oriented 3D bounding box
struct BoundingBox3D: Codable {
    /// Center point of the box in world coordinates
    var center: SIMD3<Float>

    /// Half-extents (half the size) along each local axis
    var extents: SIMD3<Float>

    /// Rotation of the box as a quaternion
    var rotation: simd_quatf

    /// Full dimensions (width, height, depth)
    var dimensions: SIMD3<Float> {
        extents * 2
    }

    /// Volume of the box in cubic meters
    var volume: Float {
        dimensions.x * dimensions.y * dimensions.z
    }

    /// The 8 corners of the box in world coordinates
    var corners: [SIMD3<Float>] {
        let localCorners: [SIMD3<Float>] = [
            SIMD3(-1, -1, -1),
            SIMD3( 1, -1, -1),
            SIMD3( 1,  1, -1),
            SIMD3(-1,  1, -1),
            SIMD3(-1, -1,  1),
            SIMD3( 1, -1,  1),
            SIMD3( 1,  1,  1),
            SIMD3(-1,  1,  1)
        ]

        return localCorners.map { localCorner in
            let scaled = localCorner * extents
            let rotated = rotation.act(scaled)
            return center + rotated
        }
    }

    /// The 12 edges of the box as pairs of corner indices
    static let edgeIndices: [(Int, Int)] = [
        // Bottom face
        (0, 1), (1, 2), (2, 3), (3, 0),
        // Top face
        (4, 5), (5, 6), (6, 7), (7, 4),
        // Vertical edges
        (0, 4), (1, 5), (2, 6), (3, 7)
    ]

    /// Get the edges as pairs of world-space points
    var edges: [(SIMD3<Float>, SIMD3<Float>)] {
        let boxCorners = corners
        return Self.edgeIndices.map { (boxCorners[$0.0], boxCorners[$0.1]) }
    }

    /// Get the local axes of the box
    var localAxes: (x: SIMD3<Float>, y: SIMD3<Float>, z: SIMD3<Float>) {
        let x = rotation.act(SIMD3<Float>(1, 0, 0))
        let y = rotation.act(SIMD3<Float>(0, 1, 0))
        let z = rotation.act(SIMD3<Float>(0, 0, 1))
        return (x, y, z)
    }

    /// Get the sorted dimensions (length >= width >= height) with their corresponding axes
    var sortedDimensions: [(dimension: Float, axis: SIMD3<Float>)] {
        let axes = localAxes
        let dims = [
            (dimensions.x, axes.x),
            (dimensions.y, axes.y),
            (dimensions.z, axes.z)
        ]
        return dims.sorted { $0.0 > $1.0 }
    }

    /// Length (longest dimension)
    var length: Float {
        sortedDimensions[0].dimension
    }

    /// Width (middle dimension)
    var width: Float {
        sortedDimensions[1].dimension
    }

    /// Height (shortest dimension)
    var height: Float {
        sortedDimensions[2].dimension
    }

    // MARK: - Camera-based Axis Mapping

    /// Axis mapping that defines which local axis corresponds to height, length, and width
    /// - height: 0=x, 1=y, 2=z - axis most aligned with world Y (vertical)
    /// - length: 0=x, 1=y, 2=z - axis most aligned with camera depth direction
    /// - width: 0=x, 1=y, 2=z - axis most aligned with camera horizontal direction
    typealias AxisMapping = (height: Int, length: Int, width: Int)

    /// Calculate axis mapping based on camera orientation
    /// - Parameter cameraTransform: The camera's transform matrix
    /// - Returns: Tuple of (heightAxisIndex, lengthAxisIndex, widthAxisIndex)
    func calculateAxisMapping(cameraTransform: simd_float4x4) -> AxisMapping {
        let axes = localAxes
        let worldUp = SIMD3<Float>(0, 1, 0)

        // Camera forward direction (horizontal component only for depth)
        let cameraForwardRaw = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            0,
            cameraTransform.columns.2.z
        )
        let cameraForwardNorm = simd_length(cameraForwardRaw) > 0.01
            ? simd_normalize(cameraForwardRaw)
            : SIMD3<Float>(0, 0, -1)

        let axisArray = [axes.x, axes.y, axes.z]

        // Height: axis most aligned with world Y (vertical direction)
        let heightIndex = (0..<3).max { i, j in
            abs(simd_dot(axisArray[i], worldUp)) < abs(simd_dot(axisArray[j], worldUp))
        }!

        // Remaining indices (the two horizontal axes)
        let remaining = [0, 1, 2].filter { $0 != heightIndex }

        // Length: remaining axis most aligned with camera forward (depth direction)
        let lengthIndex = remaining.max { i, j in
            abs(simd_dot(axisArray[i], cameraForwardNorm)) < abs(simd_dot(axisArray[j], cameraForwardNorm))
        }!

        // Width: the other remaining axis (horizontal/lateral direction)
        let widthIndex = remaining.first { $0 != lengthIndex }!

        return (heightIndex, lengthIndex, widthIndex)
    }

    /// Get dimensions using a fixed axis mapping
    /// - Parameter mapping: The axis mapping to use
    /// - Returns: Tuple of (height, length, width) in meters
    func dimensions(withMapping mapping: AxisMapping) -> (height: Float, length: Float, width: Float) {
        let dims = [dimensions.x, dimensions.y, dimensions.z]
        return (dims[mapping.height], dims[mapping.length], dims[mapping.width])
    }

    init(center: SIMD3<Float>, extents: SIMD3<Float>, rotation: simd_quatf) {
        self.center = center
        self.extents = extents
        self.rotation = rotation
    }

    /// Create from center, full dimensions, and rotation matrix
    init(center: SIMD3<Float>, dimensions: SIMD3<Float>, rotationMatrix: simd_float3x3) {
        self.center = center
        self.extents = dimensions / 2
        self.rotation = simd_quatf(rotationMatrix: rotationMatrix)
    }

    /// Create an axis-aligned bounding box
    static func axisAligned(min: SIMD3<Float>, max: SIMD3<Float>) -> BoundingBox3D {
        let center = (min + max) / 2
        let extents = (max - min) / 2
        return BoundingBox3D(center: center, extents: extents, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }

    /// Transform a point from world space to local box space
    func worldToLocal(_ worldPoint: SIMD3<Float>) -> SIMD3<Float> {
        let centered = worldPoint - center
        return rotation.inverse.act(centered)
    }

    /// Transform a point from local box space to world space
    func localToWorld(_ localPoint: SIMD3<Float>) -> SIMD3<Float> {
        let rotated = rotation.act(localPoint)
        return rotated + center
    }

    /// Check if a world-space point is inside the box
    func contains(_ worldPoint: SIMD3<Float>) -> Bool {
        let local = worldToLocal(worldPoint)
        return abs(local.x) <= extents.x &&
               abs(local.y) <= extents.y &&
               abs(local.z) <= extents.z
    }

    /// Translate the box
    mutating func translate(by offset: SIMD3<Float>) {
        center += offset
    }

    /// Scale the box uniformly
    mutating func scale(by factor: Float) {
        extents *= factor
    }

    /// Scale the box along a specific local axis
    mutating func scale(alongAxis axisIndex: Int, by factor: Float) {
        switch axisIndex {
        case 0: extents.x *= factor
        case 1: extents.y *= factor
        case 2: extents.z *= factor
        default: break
        }
    }

    /// Rotate the box around the world Y axis
    mutating func rotateAroundY(by angle: Float) {
        let yRotation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        rotation = yRotation * rotation
    }

    /// Extend the bottom face to the floor while keeping the top face fixed
    /// - Parameters:
    ///   - floorY: The world Y coordinate of the floor
    ///   - threshold: Maximum distance to extend (default 0.05m = 5cm)
    /// - Returns: true if extension was performed
    @discardableResult
    mutating func extendBottomToFloor(floorY: Float, threshold: Float = 0.05) -> Bool {
        // Calculate the world Y coordinate of the bottom center
        let bottomCenterLocal = SIMD3<Float>(0, -extents.y, 0)
        let bottomCenterWorld = localToWorld(bottomCenterLocal)

        // Distance from floor (positive = above floor)
        let distanceToFloor = bottomCenterWorld.y - floorY

        // Only extend if above floor and within threshold
        guard distanceToFloor > 0 && distanceToFloor <= threshold else {
            return false
        }

        // Calculate current top face Y (this stays fixed)
        let topCenterLocal = SIMD3<Float>(0, extents.y, 0)
        let topCenterWorld = localToWorld(topCenterLocal)
        let topWorldY = topCenterWorld.y

        // Calculate new dimensions keeping top fixed
        let newHalfHeight = (topWorldY - floorY) / 2
        let newCenterY = floorY + newHalfHeight

        center.y = newCenterY
        extents.y = newHalfHeight

        return true
    }
}

// MARK: - Codable for simd types

extension SIMD3: Codable where Scalar == Float {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Float.self)
        let y = try container.decode(Float.self)
        let z = try container.decode(Float.self)
        self.init(x, y, z)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
    }
}

extension simd_quatf: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Float.self)
        let y = try container.decode(Float.self)
        let z = try container.decode(Float.self)
        let w = try container.decode(Float.self)
        self.init(ix: x, iy: y, iz: z, r: w)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(imag.x)
        try container.encode(imag.y)
        try container.encode(imag.z)
        try container.encode(real)
    }
}
