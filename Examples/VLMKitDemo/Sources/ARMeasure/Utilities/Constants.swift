//
//  Constants.swift
//  SnapMeasure
//

import Foundation

enum AppConstants {
    // MARK: - Point Cloud Processing
    static let maxPointCloudSize = 20000
    static let pointCloudGridSize: Float = 0.003 // 3mm grid

    // MARK: - Depth Processing
    static let minDepthConfidence: Float = 0.4
    static let highDepthConfidence: Float = 0.7
    static let minDepthCoverage: Float = 0.5
    static let highDepthCoverage: Float = 0.8

    // MARK: - Outlier Removal
    static let outlierStdDevThreshold: Float = 2.0
    static let ransacIterations = 100
    static let ransacDistanceThreshold: Float = 0.02 // 2cm

    // MARK: - UI
    static let boxLineWidth: Float = 0.002
    static let handleRadius: Float = 0.01
    static let labelFontSize: CGFloat = 14

    // MARK: - Measurement
    static let defaultUnit: MeasurementUnit = .centimeters
    static let defaultRounding: RoundingPrecision = .millimeter1

    // MARK: - Refinement
    static let maxRefinementRounds = 3
    static let maxSecondTapAttempts = 3
    static let refinementProximityScale: Float = 2.0   // Scale factor for same-object validation
    static let refinementOverlapThreshold: Float = 0.30 // Minimum overlap ratio for new point cloud

    // MARK: - Depth Filtering
    static let depthFilterPercentTolerance: Float = 0.15
    static let depthFilterMinTolerance: Float = 0.05
    static let depthFilterMaxTolerance: Float = 0.15

    // MARK: - Box Refinement
    static let boxRefinementMargin: Float = 0.015
    static let boxRefinementMinRetainRatio: Float = 0.5
    static let boxRefinementIterations: Int = 2

    // MARK: - MABR Fine Angle Search
    static let mabrFineSearchRange: Float = 5.0 * .pi / 180.0
    static let mabrFineSearchStep: Float = 0.5 * .pi / 180.0
    static let mabrFineSearchStepEnhanced: Float = 0.2 * .pi / 180.0

    // MARK: - Enhanced Pipeline
    static let floorSnapThresholdDefault: Float = 0.15
    static let floorSnapThresholdWithPlane: Float = 0.25
    static let clusteringMinThreshold: Float = 0.02
    static let clusteringMaxThreshold: Float = 0.045
    static let clusteringDepthScale: Float = 0.015
    static let clusteringBaseOffset: Float = 0.02

    // MARK: - Pipeline Version
    static var currentPipelineVersion: PipelineVersion {
        #if DEBUG
        let raw = UserDefaults.standard.string(forKey: "pipelineVersion") ?? PipelineVersion.standard.rawValue
        return PipelineVersion(rawValue: raw) ?? .standard
        #else
        return .standard
        #endif
    }

    // MARK: - Vertical Plane Snap
    static let planeSnapProximityWeight: Float = 0.5
    static let planeSnapAlignmentWeight: Float = 0.3
    static let planeSnapAreaWeight: Float = 0.2

    // MARK: - Depth Connectivity Refinement
    static let depthConnectivitySeedTolerance: Float = 0.10   // ±10% of seed depth
    static let depthConnectivityLocalTolerance: Float = 0.05  // ±5% local continuity
    static let depthConnectivityMinRetainRatio: Float = 0.05  // Minimum 5% retention
    static let depthConnectivityCellSize: Int = 15             // Spatial hash cell size (px)

    // MARK: - Extent Trimming
    static let extentsTrimPercent: Float = 0.01

    // MARK: - Stability Detection
    static let stabilityPositionThreshold: Float = 0.007  // 7mm (accommodates hand tremor)
    static let stabilityRotationThreshold: Float = 0.012  // ~0.7°
    static let stabilitySettlingTime: Double = 0.3
    static let stabilityStableTime: Double = 0.7
    static let stabilityLockedTime: Double = 1.3
    static let stabilityEMAAlpha: Float = 0.15            // Smooth over ~7 frames
    static let stabilityViolationTolerance: Int = 4       // Frames before demotion

    // MARK: - Reticle Lock-On
    static let reticleMinDepth: Float = 0.15          // 15cm closer is ignored
    static let reticleMaxDepth: Float = 3.0           // 3m farther is ignored
    static let reticleDepthDiscontinuity: Float = 0.05 // 5cm depth edge detection
    static let reticleDepthEMAAlpha: Float = 0.20     // Depth smoothing
    static let reticleTargetFrameThreshold: Int = 3   // Frames for state transition
    static let reticleBackgroundSegInterval: TimeInterval = 0.35 // Segmentation interval
    static let reticleCacheFreshnessTime: TimeInterval = 0.15    // Cache validity
    static let reticleCacheMaxMovement: Float = 0.02             // 2cm
    static let reticleTapCenterThreshold: CGFloat = 0.15         // 15% of screen diagonal

    // MARK: - Label Reader
    static let labelMinConfidence: Float = 0.6
    static let labelMinSize: Float = 0.1
    static let labelLiftDuration: Double = 1.2
    static let labelTypingStagger: Double = 0.12
    static let labelMaxArea: Float = 0.55
    static let labelAreaWeight: Float = 0.5
}


enum PipelineVersion: String, CaseIterable, Codable {
    case originalWarehouse = "originalWarehouse"  // 64c52d0^ (Feb 6-15)
    case preSplit = "preSplit"                    // 32b7342 (Feb 17)
    case standard = "standard"
    case enhanced = "enhanced"

    var displayName: String {
        switch self {
        case .originalWarehouse: return "v1 Original"
        case .preSplit: return "v2 Pre-Split"
        case .standard: return "Standard"
        case .enhanced: return "Enhanced"
        }
    }

    var description: String {
        switch self {
        case .originalWarehouse: return "Original warehouse pipeline (Feb 6-15). Wide depth filter, area-only plane snap, no fine angle search."
        case .preSplit: return "Post-accuracy-fix, pre-split (Feb 17). Tighter depth, fine angle search, weighted plane snap."
        case .standard: return "Default pipeline. Fixed 4cm clustering, 0.5° MABR step, raycast floor."
        case .enhanced: return "Depth-adaptive clustering (3-6cm), 0.2° MABR step, plane-based floor detection."
        }
    }

    // MARK: - Segmentation

    var useInstanceMaskLookup: Bool {
        switch self {
        case .originalWarehouse, .preSplit: return false
        case .standard, .enhanced: return true
        }
    }

    // MARK: - Pre-3D Refinement

    var use2DConnectedComponent: Bool {
        switch self {
        case .originalWarehouse, .preSplit: return false
        case .standard, .enhanced: return true
        }
    }

    var useDepthConnectivity: Bool {
        switch self {
        case .originalWarehouse, .preSplit: return false
        case .standard, .enhanced: return true
        }
    }

    // MARK: - Depth Filter

    var useAdaptiveDepthFilter: Bool {
        switch self {
        case .originalWarehouse, .preSplit: return false
        case .standard, .enhanced: return true
        }
    }

    var depthFilterPercent: Float {
        switch self {
        case .originalWarehouse: return 0.25
        case .preSplit: return 0.20
        case .standard, .enhanced: return 0.15
        }
    }

    var depthFilterMin: Float {
        switch self {
        case .originalWarehouse: return 0.10
        case .preSplit: return 0.07
        case .standard, .enhanced: return 0.05
        }
    }

    /// Max depth tolerance. nil = no upper clamp (v1 original behavior)
    var depthFilterMax: Float? {
        switch self {
        case .originalWarehouse: return nil
        case .preSplit: return 0.25
        case .standard, .enhanced: return 0.15
        }
    }

    /// When too few pixels pass depth filter: true = return original pixels, false = return empty
    var depthFilterReturnsOriginalOnTooFew: Bool {
        switch self {
        case .originalWarehouse, .preSplit: return true
        case .standard, .enhanced: return false
        }
    }

    // MARK: - Proximity Filter

    var proximityMinRadius: Float {
        switch self {
        case .originalWarehouse, .preSplit: return 1.0
        case .standard, .enhanced: return 0.5
        }
    }

    var proximitySpreadScale: Float {
        switch self {
        case .originalWarehouse, .preSplit: return 1.0
        case .standard, .enhanced: return 0.8
        }
    }

    // MARK: - Clustering

    /// Fixed clustering threshold. nil = adaptive (enhanced only)
    var clusteringFixedThreshold: Float? {
        switch self {
        case .originalWarehouse, .preSplit, .standard: return 0.04
        case .enhanced: return nil
        }
    }

    var clusteringMinPoints: Int {
        switch self {
        case .originalWarehouse, .preSplit: return 30
        case .standard, .enhanced: return 15
        }
    }

    var clusteringFallbackMinPoints: Int {
        switch self {
        case .originalWarehouse, .preSplit: return 10
        case .standard, .enhanced: return 8
        }
    }

    var clusteringGuardMinPoints: Int {
        switch self {
        case .originalWarehouse, .preSplit: return 20
        case .standard, .enhanced: return 12
        }
    }

    // MARK: - Bounding Box Estimation

    var useFineAngleSearch: Bool {
        switch self {
        case .originalWarehouse: return false
        case .preSplit, .standard, .enhanced: return true
        }
    }

    var mabrStep: Float {
        switch self {
        case .originalWarehouse, .preSplit, .standard:
            return 0.5 * .pi / 180.0
        case .enhanced:
            return 0.2 * .pi / 180.0
        }
    }

    var useWeightedPlaneSnap: Bool {
        switch self {
        case .originalWarehouse: return false
        case .preSplit, .standard, .enhanced: return true
        }
    }

    var boxRefinementIterations: Int {
        switch self {
        case .originalWarehouse: return 1
        case .preSplit, .standard, .enhanced: return 2
        }
    }

    // MARK: - Floor Detection

    var useARPlaneFloor: Bool {
        switch self {
        case .originalWarehouse, .preSplit: return false
        case .standard, .enhanced: return true
        }
    }

    var floorSnapDefault: Float {
        switch self {
        case .originalWarehouse, .preSplit: return 0.05
        case .standard, .enhanced: return 0.15
        }
    }

    var floorSnapWithPlane: Float {
        switch self {
        case .originalWarehouse, .preSplit: return 0.05
        case .standard, .enhanced: return 0.25
        }
    }
}

enum MeasurementUnit: String, CaseIterable, Codable {
    case millimeters = "mm"
    case centimeters = "cm"
    case inches = "in"

    var displayName: String {
        switch self {
        case .millimeters: return String(localized: "Millimeters (mm)")
        case .centimeters: return String(localized: "Centimeters (cm)")
        case .inches: return String(localized: "Inches (in)")
        }
    }

    func convert(meters: Float) -> Float {
        switch self {
        case .millimeters: return meters * 1000
        case .centimeters: return meters * 100
        case .inches: return meters * 39.3701
        }
    }

    func volumeUnit() -> String {
        switch self {
        case .millimeters: return "mm³"
        case .centimeters: return "cm³"
        case .inches: return "in³"
        }
    }

    func convertVolume(cubicMeters: Float) -> Float {
        switch self {
        case .millimeters: return cubicMeters * 1e9
        case .centimeters: return cubicMeters * 1e6
        case .inches: return cubicMeters * 61023.7
        }
    }

    /// Format a dimension value with adaptive decimal places
    func formatDimension(meters: Float) -> String {
        let value = convert(meters: meters)
        let numStr: String
        if value >= 100 {
            numStr = String(format: "%.0f", value)
        } else if value >= 10 {
            numStr = String(format: "%.1f", value)
        } else {
            numStr = String(format: "%.2f", value)
        }
        return "\(numStr) \(rawValue)"
    }

    /// Volumetric weight: (L_cm x W_cm x H_cm) / 5000 = kg
    /// Equivalent to cubicMeters * 1e6 / 5000 = cubicMeters * 200
    func formatVolumetricWeight(cubicMeters: Float) -> String {
        let kg = cubicMeters * 200.0
        return String(format: "%.2f kg", kg)
    }
}

enum RoundingPrecision: String, CaseIterable, Codable {
    case millimeter1 = "1mm"
    case millimeter5 = "5mm"
    case centimeter01 = "0.1cm"
    case centimeter1 = "1cm"

    var displayName: String {
        switch self {
        case .millimeter1: return "1 mm"
        case .millimeter5: return "5 mm"
        case .centimeter01: return "0.1 cm"
        case .centimeter1: return "1 cm"
        }
    }

    func round(meters: Float) -> Float {
        let precision: Float
        switch self {
        case .millimeter1: precision = 0.001
        case .millimeter5: precision = 0.005
        case .centimeter01: precision = 0.001
        case .centimeter1: precision = 0.01
        }
        return (meters / precision).rounded() * precision
    }
}

enum MeasurementMode: String, CaseIterable, Codable {
    case boxPriority = "box"
    case freeObject = "free"

    var displayName: String {
        switch self {
        case .boxPriority: return String(localized: "Box Priority")
        case .freeObject: return String(localized: "Free Object")
        }
    }

    var description: String {
        switch self {
        case .boxPriority: return String(localized: "Optimized for box-shaped objects on surfaces. Locks vertical axis.")
        case .freeObject: return String(localized: "For irregularly shaped or tilted objects. Full 3D rotation.")
        }
    }
}

enum ShippingSize: String, CaseIterable {
    case s60 = "60"
    case s80 = "80"
    case s100 = "100"
    case s120 = "120"
    case s140 = "140"
    case s160 = "160"
    case s170 = "170"
    case s200 = "200"
    case oversize = "200+"

    var displayName: String { rawValue }

    /// Classify based on sum of 3 dimensions in cm (Japanese domestic shipping standard)
    static func classify(lengthMeters: Float, widthMeters: Float, heightMeters: Float) -> ShippingSize {
        let sumCm = Double(lengthMeters + widthMeters + heightMeters) * 100.0
        switch sumCm {
        case ...60: return .s60
        case ...80: return .s80
        case ...100: return .s100
        case ...120: return .s120
        case ...140: return .s140
        case ...160: return .s160
        case ...170: return .s170
        case ...200: return .s200
        default: return .oversize
        }
    }

    /// Classify from a BoundingBox3D
    static func classify(boundingBox: BoundingBox3D) -> ShippingSize {
        let e = boundingBox.extents
        return classify(lengthMeters: e.x, widthMeters: e.y, heightMeters: e.z)
    }
}

enum WorkflowStep: Equatable {
    case idle
    case awaitingSecondTap
    case showingResult
}

enum ReticleTargetState: Int {
    case noTarget = 0       // Empty space or too far
    case targetDetected = 1 // Object present (even while device moving)
    case targetLocked = 2   // Object present + device stable
}

enum StabilityLevel: Int, Comparable {
    case moving = 0
    case settling = 1
    case stable = 2
    case locked = 3

    static func < (lhs: StabilityLevel, rhs: StabilityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum SelectionMode: String, CaseIterable, Codable {
    case tap = "tap"
    case box = "box"

    var displayName: String {
        switch self {
        case .tap: return String(localized: "Tap")
        case .box: return String(localized: "Box")
        }
    }

    var icon: String {
        switch self {
        case .tap: return "hand.tap"
        case .box: return "rectangle.dashed"
        }
    }
}

// MARK: - AppStorage Conformances

extension MeasurementUnit: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "mm": self = .millimeters
        case "cm": self = .centimeters
        case "in": self = .inches
        default: return nil
        }
    }
}

extension RoundingPrecision: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "1mm": self = .millimeter1
        case "5mm": self = .millimeter5
        case "0.1cm": self = .centimeter01
        case "1cm": self = .centimeter1
        default: return nil
        }
    }
}

extension MeasurementMode: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "box": self = .boxPriority
        case "free": self = .freeObject
        default: return nil
        }
    }
}

extension PipelineVersion: RawRepresentable {
    public init?(rawValue: String) {
        switch rawValue {
        case "originalWarehouse": self = .originalWarehouse
        case "preSplit": self = .preSplit
        case "standard": self = .standard
        case "enhanced": self = .enhanced
        default: return nil
        }
    }
}
