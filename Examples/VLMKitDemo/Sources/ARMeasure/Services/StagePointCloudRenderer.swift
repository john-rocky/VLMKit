//
//  StagePointCloudRenderer.swift
//  SnapMeasure
//

#if DEBUG
import RealityKit
import UIKit
import simd

/// Renders pipeline stage point clouds as colored markers in AR space.
/// Uses batched geometry (single mesh per color) for minimal memory usage.
/// Green = kept points, Red = removed points vs previous stage.
enum StagePointCloudRenderer {
    /// Maximum points per color
    private static let maxPointsPerColor = 500

    /// Marker size (each point rendered as 3 crossed quads)
    private static let markerSize: Float = 0.01

    /// Create an Entity with 2 children (green kept, red removed) using batched meshes
    static func createStageEntity(
        capture: PipelinePointCloudCapture,
        stage: PipelinePointCloudCapture.Stage
    ) -> Entity {
        let root = Entity()
        root.name = "stage_point_cloud"

        let kept = strideSample(capture.keptPoints(at: stage), maxCount: maxPointsPerColor)
        let removed = strideSample(capture.removedPoints(at: stage), maxCount: maxPointsPerColor)

        if !kept.isEmpty, let mesh = createBatchedMesh(points: kept, size: markerSize) {
            var mat = UnlitMaterial()
            mat.color = .init(tint: UIColor(red: 0.2, green: 1.0, blue: 0.3, alpha: 1.0))
            let entity = ModelEntity(mesh: mesh, materials: [mat])
            entity.name = "kept"
            root.addChild(entity)
        }

        if !removed.isEmpty, let mesh = createBatchedMesh(points: removed, size: markerSize) {
            var mat = UnlitMaterial()
            mat.color = .init(tint: UIColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 1.0))
            let entity = ModelEntity(mesh: mesh, materials: [mat])
            entity.name = "removed"
            root.addChild(entity)
        }

        print("[StageRenderer] '\(stage.displayName)': \(kept.count) green, \(removed.count) red points (2 entities)")
        return root
    }

    // MARK: - Batched Mesh

    /// Create a single MeshResource with 3 crossed quads per point (visible from all angles)
    private static func createBatchedMesh(points: [SIMD3<Float>], size: Float) -> MeshResource? {
        guard !points.isEmpty else { return nil }

        let h = size / 2
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        positions.reserveCapacity(points.count * 12)
        normals.reserveCapacity(points.count * 12)
        indices.reserveCapacity(points.count * 18)

        for (i, c) in points.enumerated() {
            let base = UInt32(i * 12)

            // XY quad (faces Z)
            positions.append(c + SIMD3<Float>(-h, -h, 0))
            positions.append(c + SIMD3<Float>( h, -h, 0))
            positions.append(c + SIMD3<Float>( h,  h, 0))
            positions.append(c + SIMD3<Float>(-h,  h, 0))
            normals.append(contentsOf: Array(repeating: SIMD3<Float>(0, 0, 1), count: 4))
            indices.append(contentsOf: [base, base+1, base+2, base, base+2, base+3])

            // XZ quad (faces Y)
            positions.append(c + SIMD3<Float>(-h, 0, -h))
            positions.append(c + SIMD3<Float>( h, 0, -h))
            positions.append(c + SIMD3<Float>( h, 0,  h))
            positions.append(c + SIMD3<Float>(-h, 0,  h))
            normals.append(contentsOf: Array(repeating: SIMD3<Float>(0, 1, 0), count: 4))
            indices.append(contentsOf: [base+4, base+5, base+6, base+4, base+6, base+7])

            // YZ quad (faces X)
            positions.append(c + SIMD3<Float>(0, -h, -h))
            positions.append(c + SIMD3<Float>(0,  h, -h))
            positions.append(c + SIMD3<Float>(0,  h,  h))
            positions.append(c + SIMD3<Float>(0, -h,  h))
            normals.append(contentsOf: Array(repeating: SIMD3<Float>(1, 0, 0), count: 4))
            indices.append(contentsOf: [base+8, base+9, base+10, base+8, base+10, base+11])
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)

        return try? MeshResource.generate(from: [descriptor])
    }

    // MARK: - Sampling

    private static func strideSample(_ points: [SIMD3<Float>], maxCount: Int) -> [SIMD3<Float>] {
        guard points.count > maxCount else { return points }
        let stride = max(1, points.count / maxCount)
        return Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
    }
}
#endif
