//
//  Measurement.swift
//  SnapMeasure
//

import Foundation
// import SwiftData removed: persistence stripped for VLMKit demo embedding
import simd

// @Model removed: persistence stripped for VLMKit demo embedding
final class ProductMeasurement {
    /// Unique identifier
    var id: UUID

    /// Timestamp when the measurement was taken
    var timestamp: Date

    /// Dimensions in meters (length, width, height - sorted largest to smallest)
    var lengthMeters: Float
    var widthMeters: Float
    var heightMeters: Float

    /// Volume in cubic meters
    var volumeCubicMeters: Float

    /// Box center position (x, y, z)
    var centerX: Float
    var centerY: Float
    var centerZ: Float

    /// Box extents (half-dimensions)
    var extentX: Float
    var extentY: Float
    var extentZ: Float

    /// Box rotation quaternion (x, y, z, w)
    var rotationX: Float
    var rotationY: Float
    var rotationZ: Float
    var rotationW: Float

    /// Quality metrics
    var depthCoverage: Float
    var depthConfidence: Float
    var pointCount: Int
    var trackingStateDescription: String
    var trackingNormal: Bool

    /// Optional annotated image (JPEG data).
    /// (Originally `@Attribute(.externalStorage)` for SwiftData — stripped along
    /// with `@Model` when porting into ShelfScout; now a plain property.)
    var annotatedImageData: Data?

    /// User notes
    var notes: String

    /// JSON-encoded label data (if a label was scanned before this measurement)
    var labelDataJSON: String?

    /// Computed property to get/set LabelData
    var labelData: LabelData? {
        get {
            guard let json = labelDataJSON, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(LabelData.self, from: data)
        }
        set {
            if let value = newValue, let data = try? JSONEncoder().encode(value) {
                labelDataJSON = String(data: data, encoding: .utf8)
            } else {
                labelDataJSON = nil
            }
        }
    }

    /// Measurement mode used
    var measurementModeRaw: String

    var measurementMode: MeasurementMode {
        get { MeasurementMode(rawValue: measurementModeRaw) ?? .boxPriority }
        set { measurementModeRaw = newValue.rawValue }
    }

    /// Computed property to reconstruct BoundingBox3D
    var boundingBox: BoundingBox3D {
        get {
            BoundingBox3D(
                center: SIMD3<Float>(centerX, centerY, centerZ),
                extents: SIMD3<Float>(extentX, extentY, extentZ),
                rotation: simd_quatf(ix: rotationX, iy: rotationY, iz: rotationZ, r: rotationW)
            )
        }
        set {
            centerX = newValue.center.x
            centerY = newValue.center.y
            centerZ = newValue.center.z
            extentX = newValue.extents.x
            extentY = newValue.extents.y
            extentZ = newValue.extents.z
            rotationX = newValue.rotation.imag.x
            rotationY = newValue.rotation.imag.y
            rotationZ = newValue.rotation.imag.z
            rotationW = newValue.rotation.real
        }
    }

    /// Computed property to reconstruct MeasurementQuality
    var quality: MeasurementQuality {
        MeasurementQuality(
            depthCoverage: depthCoverage,
            depthConfidence: depthConfidence,
            pointCount: pointCount,
            trackingStateDescription: trackingStateDescription,
            trackingNormal: trackingNormal
        )
    }

    init(
        boundingBox: BoundingBox3D,
        quality: MeasurementQuality,
        mode: MeasurementMode,
        annotatedImageData: Data? = nil,
        notes: String = "",
        labelData: LabelData? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()

        // Store sorted dimensions
        let sorted = boundingBox.sortedDimensions
        self.lengthMeters = sorted[0].dimension
        self.widthMeters = sorted[1].dimension
        self.heightMeters = sorted[2].dimension
        self.volumeCubicMeters = boundingBox.volume

        // Store box geometry
        self.centerX = boundingBox.center.x
        self.centerY = boundingBox.center.y
        self.centerZ = boundingBox.center.z
        self.extentX = boundingBox.extents.x
        self.extentY = boundingBox.extents.y
        self.extentZ = boundingBox.extents.z
        self.rotationX = boundingBox.rotation.imag.x
        self.rotationY = boundingBox.rotation.imag.y
        self.rotationZ = boundingBox.rotation.imag.z
        self.rotationW = boundingBox.rotation.real

        // Store quality metrics
        self.depthCoverage = quality.depthCoverage
        self.depthConfidence = quality.depthConfidence
        self.pointCount = quality.pointCount
        self.trackingStateDescription = quality.trackingStateDescription
        self.trackingNormal = quality.trackingNormal

        self.annotatedImageData = annotatedImageData
        self.notes = notes
        self.measurementModeRaw = mode.rawValue

        // Encode label data if provided
        if let labelData = labelData, let data = try? JSONEncoder().encode(labelData) {
            self.labelDataJSON = String(data: data, encoding: .utf8)
        }
    }

    /// Get formatted dimensions string
    func formattedDimensions(unit: MeasurementUnit, precision: RoundingPrecision) -> String {
        let l = precision.round(meters: lengthMeters)
        let w = precision.round(meters: widthMeters)
        let h = precision.round(meters: heightMeters)

        let lUnit = unit.convert(meters: l)
        let wUnit = unit.convert(meters: w)
        let hUnit = unit.convert(meters: h)

        return String(format: "%.1f × %.1f × %.1f %@", lUnit, wUnit, hUnit, unit.rawValue)
    }

    /// Get formatted volume string
    func formattedVolume(unit: MeasurementUnit) -> String {
        let vol = unit.convertVolume(cubicMeters: volumeCubicMeters)
        if vol >= 1000 {
            return String(format: "%.0f %@", vol, unit.volumeUnit())
        } else if vol >= 100 {
            return String(format: "%.1f %@", vol, unit.volumeUnit())
        } else {
            return String(format: "%.2f %@", vol, unit.volumeUnit())
        }
    }
}
