//
//  LabelReaderService.swift
//  SnapMeasure
//

import Foundation
import Vision
import ARKit
import CoreImage
import UIKit

/// Detects rectangular labels on box surfaces, performs perspective correction,
/// OCR + barcode detection, and returns parsed label data.
class LabelReaderService {

    /// Dedicated serial queues per Vision task type — enables true parallelism
    /// and isolates first-use ML model init latency per request type.
    private static let rectQueue = DispatchQueue(label: "com.productmeasure.vision.rect", qos: .userInitiated)
    private static let ocrQueue = DispatchQueue(label: "com.productmeasure.vision.ocr", qos: .userInitiated)
    private static let barcodeQueue = DispatchQueue(label: "com.productmeasure.vision.barcode", qos: .userInitiated)

    /// Shared CIContext — avoids recreating on every perspectiveCorrect() call.
    private static let ciContext = CIContext()

    /// Whether ML models have been pre-loaded via warmup().
    private static var isWarmedUp = false

    /// Pre-load Vision ML models on background queues so the first real scan is instant.
    /// Safe to call multiple times; only the first invocation performs work.
    static func warmup() {
        guard !isWarmedUp else { return }
        isWarmedUp = true

        // 256x256 dummy image with text-like content — large enough to trigger
        // full Vision pipeline (1x1 images cause Vision to skip model loading).
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            for y in stride(from: 30, to: 220, by: 18) {
                ctx.fill(CGRect(x: 20, y: y, width: 200, height: 3))
            }
        }
        guard let cgImage = uiImage.cgImage else {
#if DEBUG
            print("[LabelReader] Warmup: failed to create dummy image")
#endif
            return
        }

        let start = CFAbsoluteTimeGetCurrent()

        // Rectangle detection warmup
        rectQueue.async {
            let req = VNDetectRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([req])
#if DEBUG
            print("[LabelReader] Rectangle detection warmed up (\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s)")
#endif
        }

        // OCR warmup (heaviest — accurate level loads ~100MB model)
        ocrQueue.async {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["en-US"]
            req.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([req])
#if DEBUG
            print("[LabelReader] OCR warmed up (\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s)")
#endif
        }

        // Barcode detection warmup
        barcodeQueue.async {
            let req = VNDetectBarcodesRequest()
            req.symbologies = [.qr, .ean13, .code128, .code39, .dataMatrix, .itf14]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([req])
#if DEBUG
            print("[LabelReader] Barcode detection warmed up (\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s)")
#endif
        }

        // CIContext GPU warmup — first render initializes Metal pipeline
        DispatchQueue.global(qos: .utility).async {
            let ci = CIImage(cgImage: cgImage)
            _ = ciContext.createCGImage(ci, from: ci.extent)
#if DEBUG
            print("[LabelReader] CIContext warmed up (\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start))s)")
#endif
        }
    }

    struct LabelDetectionResult {
        let quadrilateral: VNRectangleObservation
        let correctedImage: UIImage
        let labelData: LabelData
        let worldCorners: [SIMD3<Float>]?
        let surfaceNormal: SIMD3<Float>?
    }

    // MARK: - Main Entry Point

    func detectAndReadLabel(
        frame: ARFrame,
        tapPoint: CGPoint,
        viewSize: CGSize
    ) async throws -> LabelDetectionResult? {
        let pixelBuffer = frame.capturedImage

        // Step 1: Detect rectangles
        guard let rectangle = try await detectRectangle(
            pixelBuffer: pixelBuffer,
            tapPoint: tapPoint,
            viewSize: viewSize
        ) else {
#if DEBUG
            print("[LabelReader] No rectangle detected near tap point")
#endif
            return nil
        }

        // Step 2: Perspective-correct the label image
        guard let correctedImage = perspectiveCorrect(
            pixelBuffer: pixelBuffer,
            rectangle: rectangle
        ) else {
#if DEBUG
            print("[LabelReader] Perspective correction failed")
#endif
            return nil
        }

        // Step 3: Run OCR and barcode detection concurrently
        async let ocrResult = recognizeText(image: correctedImage)
        async let barcodeResult = detectBarcodes(image: correctedImage)

        let (textObservations, barcodeObservations) = try await (ocrResult, barcodeResult)

        // Step 4: Parse fields from OCR text and barcodes
        // Reconstruct lines using spatial position so that field names and
        // values at the same height are merged into one line (e.g. "PO#  12345").
        let structuredLines = reconstructLinesStructured(from: textObservations)
        let rawText = structuredLines.map(\.joinedText).joined(separator: "\n")

        var labelData: LabelData
        if let boundary = detectColumnBoundary(lines: structuredLines) {
            // Table layout detected — use column-based parsing + regex fallback
            labelData = LabelData(rawText: rawText)
            parseTableFields(lines: structuredLines, columnBoundary: boundary, into: &labelData)
            let inlineData = parseLabelFields(rawText: rawText)
            mergeInlineParsed(from: inlineData, into: &labelData)
        } else {
            // Non-table layout — regex-only parsing
            labelData = parseLabelFields(rawText: rawText)
        }

        // Capture text line bounding boxes for scan effect
        let lineBounds = textObservations.map { $0.boundingBox }
        if !lineBounds.isEmpty {
            labelData.textLineBounds = lineBounds
        }

        // Merge barcode data (all detected barcodes)
        if !barcodeObservations.isEmpty {
            labelData.barcodes = barcodeObservations.compactMap { obs in
                guard let value = obs.payloadStringValue else { return nil }
                let sym = obs.symbology.rawValue
                    .replacingOccurrences(of: "VNBarcodeSymbology", with: "")
                return LabelData.BarcodeItem(value: value, symbology: sym, boundingBox: obs.boundingBox)
            }
            if labelData.barcodes?.isEmpty == true { labelData.barcodes = nil }
        }

        // Step 5: Compute world corners from depth map
        let worldCorners = computeWorldCorners(
            rectangle: rectangle,
            frame: frame
        )

        // Step 6: Compute surface normal
        let surfaceNormal: SIMD3<Float>?
        if let corners = worldCorners, corners.count == 4 {
            surfaceNormal = computeSurfaceNormal(corners: corners)
        } else {
            surfaceNormal = nil
        }

        return LabelDetectionResult(
            quadrilateral: rectangle,
            correctedImage: correctedImage,
            labelData: labelData,
            worldCorners: worldCorners,
            surfaceNormal: surfaceNormal
        )
    }

    // MARK: - Rectangle Detection

    /// Compute area of a quadrilateral using the Shoelace formula.
    private func quadArea(corners: [CGPoint]) -> CGFloat {
        guard corners.count == 4 else { return 0 }
        // Shoelace formula for polygon area
        var area: CGFloat = 0
        for i in 0..<4 {
            let j = (i + 1) % 4
            area += corners[i].x * corners[j].y
            area -= corners[j].x * corners[i].y
        }
        return abs(area) / 2
    }

    private func detectRectangle(
        pixelBuffer: CVPixelBuffer,
        tapPoint: CGPoint,
        viewSize: CGSize
    ) async throws -> VNRectangleObservation? {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = AppConstants.labelMinConfidence
        request.minimumSize = AppConstants.labelMinSize
        request.minimumAspectRatio = 0.3
        request.maximumObservations = 10

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .right,
            options: [:]
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.rectQueue.async {
                do {
                    try handler.perform([request])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        guard let results = request.results, !results.isEmpty else {
            return nil
        }

        // Convert tap point to Vision coordinates (bottom-left origin, 0-1)
        // Screen → Vision with .right orientation:
        // visionX = 1 - (screenY / height), visionY = screenX / width
        let visionTapX = 1.0 - (tapPoint.y / viewSize.height)
        let visionTapY = tapPoint.x / viewSize.width
        let visionTap = CGPoint(x: visionTapX, y: visionTapY)

        let maxArea = CGFloat(AppConstants.labelMaxArea)
        let areaWeight = CGFloat(AppConstants.labelAreaWeight)

        // Find best rectangle using area-weighted distance score.
        // score = distance - areaWeight * area
        // Larger rectangles get a lower score (preferred), preventing
        // inner section lines from being chosen over the full label.
        var bestRect: VNRectangleObservation?
        var bestScore: CGFloat = .greatestFiniteMagnitude

        for rect in results {
            let corners = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]
            let area = quadArea(corners: corners)

            // Skip rectangles that are too large (e.g. cardboard top surface)
            guard area < maxArea else { continue }

            let center = CGPoint(
                x: (corners[0].x + corners[1].x + corners[2].x + corners[3].x) / 4,
                y: (corners[0].y + corners[1].y + corners[2].y + corners[3].y) / 4
            )
            let dx = center.x - visionTap.x
            let dy = center.y - visionTap.y
            let dist = sqrt(dx * dx + dy * dy)

            let score = dist - areaWeight * area

            if score < bestScore {
                bestScore = score
                bestRect = rect
            }
        }

        // Distance threshold check using raw distance (not weighted score)
        if let rect = bestRect {
            let corners = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]
            let center = CGPoint(
                x: (corners[0].x + corners[1].x + corners[2].x + corners[3].x) / 4,
                y: (corners[0].y + corners[1].y + corners[2].y + corners[3].y) / 4
            )
            let dx = center.x - visionTap.x
            let dy = center.y - visionTap.y
            let rawDist = sqrt(dx * dx + dy * dy)
            if rawDist > 0.3 {
#if DEBUG
                print("[LabelReader] Best rectangle too far from tap: \(rawDist)")
#endif
                return nil
            }
        }

        return bestRect
    }

    // MARK: - Perspective Correction

    private func perspectiveCorrect(
        pixelBuffer: CVPixelBuffer,
        rectangle: VNRectangleObservation
    ) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(.right)

        let imageSize = ciImage.extent.size

        // Convert Vision normalized coords to pixel coords
        func toPixel(_ point: CGPoint) -> CIVector {
            CIVector(
                x: point.x * imageSize.width,
                y: point.y * imageSize.height
            )
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            return nil
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(toPixel(rectangle.topLeft), forKey: "inputTopLeft")
        filter.setValue(toPixel(rectangle.topRight), forKey: "inputTopRight")
        filter.setValue(toPixel(rectangle.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(toPixel(rectangle.bottomRight), forKey: "inputBottomRight")

        guard let outputImage = filter.outputImage else { return nil }

        guard let cgImage = Self.ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    // MARK: - OCR

    private func recognizeText(image: UIImage) async throws -> [VNRecognizedTextObservation] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.ocrQueue.async {
                do {
                    try handler.perform([request])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        return request.results ?? []
    }

    // MARK: - Barcode Detection

    private func detectBarcodes(image: UIImage) async throws -> [VNBarcodeObservation] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [
            .qr, .ean13, .code128, .code39, .dataMatrix, .itf14
        ]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.barcodeQueue.async {
                do {
                    try handler.perform([request])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        return request.results ?? []
    }

    // MARK: - Spatial Line Reconstruction

    /// A single text block with its bounding box.
    private struct TextBlock {
        let text: String
        let box: CGRect  // Vision normalized (bottom-left origin)
    }

    /// A reconstructed line of text blocks sorted left-to-right.
    private struct ReconstructedLine {
        let blocks: [TextBlock]
        var joinedText: String { blocks.map(\.text).joined(separator: " ") }
    }

    /// Groups text observations that share the same visual line (by Y overlap),
    /// sorts each group left-to-right, and preserves bounding boxes per block.
    private func reconstructLinesStructured(from observations: [VNRecognizedTextObservation]) -> [ReconstructedLine] {
        let blocks: [TextBlock] = observations.compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return TextBlock(text: text, box: obs.boundingBox)
        }

        guard !blocks.isEmpty else { return [] }

        // Sort by midY descending (top of image first, since Vision Y=0 is bottom)
        let sorted = blocks.sorted { $0.box.midY > $1.box.midY }

        // Group blocks whose Y ranges overlap significantly
        var groups: [[TextBlock]] = []
        var currentLine: [TextBlock] = [sorted[0]]
        var currentMinY = sorted[0].box.minY
        var currentMaxY = sorted[0].box.maxY

        for i in 1..<sorted.count {
            let block = sorted[i]
            let lineHeight = currentMaxY - currentMinY
            let blockHeight = block.box.height
            let overlapThreshold = min(lineHeight, blockHeight) * 0.4

            let overlapTop = min(currentMaxY, block.box.maxY)
            let overlapBottom = max(currentMinY, block.box.minY)
            let overlap = max(0, overlapTop - overlapBottom)

            if overlap >= overlapThreshold {
                currentLine.append(block)
                currentMinY = min(currentMinY, block.box.minY)
                currentMaxY = max(currentMaxY, block.box.maxY)
            } else {
                groups.append(currentLine)
                currentLine = [block]
                currentMinY = block.box.minY
                currentMaxY = block.box.maxY
            }
        }
        groups.append(currentLine)

        // Sort each line left-to-right by minX
        return groups.map { group in
            ReconstructedLine(blocks: group.sorted { $0.box.minX < $1.box.minX })
        }
    }

    /// Backward-compatible flat string reconstruction.
    private func reconstructLines(from observations: [VNRecognizedTextObservation]) -> String {
        reconstructLinesStructured(from: observations)
            .map(\.joinedText)
            .joined(separator: "\n")
    }

    // MARK: - Table Layout Detection

    /// Detects a two-column table layout by finding a consistent vertical gap
    /// between the first and second text blocks across multiple lines.
    /// Returns the X boundary (in Vision normalized coords) if a table is detected.
    private func detectColumnBoundary(lines: [ReconstructedLine]) -> CGFloat? {
        // Collect gap midpoints from lines with 2+ blocks
        var gapMidpoints: [CGFloat] = []
        for line in lines {
            guard line.blocks.count >= 2 else { continue }
            let left = line.blocks[0]
            let right = line.blocks[1]
            // Only consider lines where there's a meaningful gap
            let gap = right.box.minX - left.box.maxX
            guard gap > 0.02 else { continue }
            let midX = (left.box.maxX + right.box.minX) / 2.0
            gapMidpoints.append(midX)
        }

        guard gapMidpoints.count >= 3 else { return nil }

        // Compute median gap midpoint
        let sorted = gapMidpoints.sorted()
        let median = sorted[sorted.count / 2]

        // Check that enough gap midpoints cluster around the median (within 8%)
        let tolerance: CGFloat = 0.08
        let consistent = gapMidpoints.filter { abs($0 - median) < tolerance }
        guard consistent.count >= 3 else { return nil }

        return median
    }

    // MARK: - Table Field Parsing

    /// Fields that can span multiple continuation lines (e.g. multi-line addresses).
    private enum MultiLineField {
        case destination
        case contents
        case handling
        case putaway
    }

    /// Parses fields from a detected two-column table layout.
    /// Left column = field names, right column = values.
    /// Supports continuation lines: if a row has value text but no field name,
    /// it is appended to the previous multi-line-capable field.
    private func parseTableFields(lines: [ReconstructedLine], columnBoundary: CGFloat, into data: inout LabelData) {
        var lastField: MultiLineField? = nil

        for line in lines {
            guard !line.blocks.isEmpty else { continue }

            // Classify blocks into left/right columns
            var leftParts: [String] = []
            var rightParts: [String] = []
            for block in line.blocks {
                if block.box.midX < columnBoundary {
                    leftParts.append(block.text)
                } else {
                    rightParts.append(block.text)
                }
            }

            let fieldName = leftParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let value = rightParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)

            if !fieldName.isEmpty && !value.isEmpty {
                // Normal row: field name + value
                lastField = mapFieldToLabelData(fieldName: fieldName, value: value, data: &data)
            } else if fieldName.isEmpty && !value.isEmpty, let field = lastField {
                // Continuation row: value only, append to previous multi-line field
                appendContinuation(value, to: field, data: &data)
            } else if !fieldName.isEmpty && value.isEmpty {
                // Section header or label-only row — reset continuation
                lastField = nil
            }
        }
    }

    /// Appends continuation text to the appropriate LabelData property for a multi-line field.
    private func appendContinuation(_ text: String, to field: MultiLineField, data: inout LabelData) {
        switch field {
        case .destination:
            if let existing = data.destination {
                data.destination = existing + ", " + text
            }
        case .contents:
            if let existing = data.contents {
                data.contents = existing + ", " + text
            }
        case .handling:
            if let existing = data.handling {
                data.handling = existing + ", " + text
            }
        case .putaway:
            if let existing = data.putaway {
                data.putaway = existing + ", " + text
            }
        }
    }

    /// Maps a field name and value to the appropriate LabelData property.
    /// Returns the `MultiLineField` case if the field supports continuation lines, nil otherwise.
    @discardableResult
    private func mapFieldToLabelData(fieldName: String, value: String, data: inout LabelData) -> MultiLineField? {
        let name = fieldName.uppercased()

        // Combined fields like "PO / ASN"
        if name.contains("PO") && name.contains("ASN") {
            let parts = value.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                data.poNumber = parts[0]
                data.asnNumber = parts[1]
            } else {
                data.poNumber = value
            }
            return nil
        }

        // Combined "GROSS / NET" weight
        if name.contains("GROSS") && name.contains("NET") {
            let parts = value.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                data.grossWeight = parts[0]
                data.netWeight = parts[1]
            } else {
                data.grossWeight = value
            }
            return nil
        }

        if name.contains("CARTON") || name.contains("CTN") {
            if data.cartonId == nil { data.cartonId = value }
            return nil
        } else if name.contains("PO") || name.contains("PURCHASE") {
            if data.poNumber == nil { data.poNumber = value }
            return nil
        } else if name.contains("ASN") {
            if data.asnNumber == nil { data.asnNumber = value }
            return nil
        } else if name.contains("SO") && (name.contains("SALES") || name == "SO" || name.contains("SO#") || name.contains("SO ")) {
            if data.soNumber == nil { data.soNumber = value }
            return nil
        } else if name.contains("LOT") || name.contains("BATCH") {
            if data.lotNumber == nil { data.lotNumber = value }
            return nil
        } else if name.contains("DEST") || name.contains("SHIP") {
            if data.destination == nil { data.destination = value }
            return .destination
        } else if name.contains("TRACK") {
            if data.trackingNumber == nil { data.trackingNumber = value }
            return nil
        } else if name.contains("CARRIER") {
            if data.carrier == nil { data.carrier = value }
            return nil
        } else if name.contains("GROSS") {
            if data.grossWeight == nil { data.grossWeight = value }
            return nil
        } else if name.contains("NET") && name.contains("W") {
            if data.netWeight == nil { data.netWeight = value }
            return nil
        } else if name.contains("WEIGHT") || name == "WT" {
            // Generic weight — try to determine gross vs net
            if name.contains("NET") {
                if data.netWeight == nil { data.netWeight = value }
            } else {
                if data.grossWeight == nil { data.grossWeight = value }
            }
            return nil
        } else if name.contains("PACK") && name.contains("DATE") || name.contains("MFG") {
            if data.packDate == nil { data.packDate = value }
            return nil
        } else if name.contains("EXP") || name.contains("BEST BY") || name.contains("USE BY") {
            if data.expiryDate == nil { data.expiryDate = value }
            return nil
        } else if name.contains("CONTENT") {
            if data.contents == nil { data.contents = value }
            return .contents
        } else if name.contains("DIMENSION") || name.contains("DIMS") || name.contains("DIM ") || name == "DIM" {
            if data.dimensions == nil { data.dimensions = value }
            return nil
        } else if name.contains("PUTAWAY") || name.contains("PUT AWAY") || name.contains("LOCATION") {
            if data.putaway == nil { data.putaway = value }
            return .putaway
        } else if name.contains("HANDLING") {
            if data.handling == nil { data.handling = value }
            return .handling
        } else if name.contains("SKU") || name.contains("ITEM") {
            let item = LabelData.SKUItem(sku: value)
            if data.skuList == nil { data.skuList = [] }
            data.skuList?.append(item)
            return nil
        }

        return nil
    }

    /// Copies non-nil fields from an inline-parsed result into the table-parsed result,
    /// filling gaps where table parsing didn't find a match.
    private func mergeInlineParsed(from source: LabelData, into target: inout LabelData) {
        if target.cartonId == nil { target.cartonId = source.cartonId }
        if target.poNumber == nil { target.poNumber = source.poNumber }
        if target.asnNumber == nil { target.asnNumber = source.asnNumber }
        if target.soNumber == nil { target.soNumber = source.soNumber }
        if target.lotNumber == nil { target.lotNumber = source.lotNumber }
        if target.destination == nil { target.destination = source.destination }
        if target.trackingNumber == nil { target.trackingNumber = source.trackingNumber }
        if target.carrier == nil { target.carrier = source.carrier }
        if target.grossWeight == nil { target.grossWeight = source.grossWeight }
        if target.netWeight == nil { target.netWeight = source.netWeight }
        if target.packDate == nil { target.packDate = source.packDate }
        if target.expiryDate == nil { target.expiryDate = source.expiryDate }
        if target.handlingIcons == nil { target.handlingIcons = source.handlingIcons }
        if target.skuList == nil { target.skuList = source.skuList }
        if target.contents == nil { target.contents = source.contents }
        if target.dimensions == nil { target.dimensions = source.dimensions }
        if target.putaway == nil { target.putaway = source.putaway }
        if target.handling == nil { target.handling = source.handling }
    }

    // MARK: - Field Parsing

    /// Helper: extract first capture group from a regex match.
    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    /// Checks if a line starts with a recognized field keyword.
    /// Used to stop multi-line continuation collection.
    private func isFieldKeywordLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        let keywords = [
            "CARTON", "CTN", "PO", "PURCHASE ORDER", "ASN",
            "SO#", "SO ", "SALES ORDER",
            "LOT", "BATCH", "DEST", "SHIP", "DELIVER",
            "TRACK", "CARRIER", "GROSS", "NET",
            "WEIGHT", "WT", "PACK", "MFG",
            "EXP", "BEST BY", "USE BY",
            "CONTENT", "DIMENSION", "DIMS", "DIM",
            "PUTAWAY", "PUT AWAY", "LOCATION",
            "HANDLING", "SKU", "ITEM"
        ]
        for keyword in keywords {
            if upper.hasPrefix(keyword) { return true }
            // Also match "KEYWORD:" or "KEYWORD #" patterns
            if upper.contains(keyword + ":") || upper.contains(keyword + "#") { return true }
        }
        return false
    }

    private func parseLabelFields(rawText: String) -> LabelData {
        let lines = rawText.components(separatedBy: "\n")
        let fullText = rawText.uppercased()

        var data = LabelData(rawText: rawText)

        // Carton ID: CTN-YYYY-NNNNNN or CTN/CARTON followed by alphanumeric
        if let match = rawText.range(of: #"CTN[-\s]?\d{4}[-\s]?\d{4,8}"#, options: .regularExpression) {
            data.cartonId = String(rawText[match]).trimmingCharacters(in: .whitespaces)
        } else if let v = firstCapture(in: rawText, pattern: #"(?:CARTON|CTN)[\s:#]*([A-Z0-9\-]{4,})"#) {
            data.cartonId = v
        }

        // PO Number — handles "PO#", "PO:", "PO ", "P.O.", "PO NUMBER", "PURCHASE ORDER"
        if let v = firstCapture(in: rawText, pattern: #"(?:P\.?O\.?|PURCHASE\s*ORDER)[\s#:]*(?:NO|NUM(?:BER)?)?[\s#:]*([A-Z0-9][\w\-]{3,})"#) {
            data.poNumber = v
        }

        // ASN Number — handles "ASN#", "ASN:", "ASN ", "ASN NUMBER"
        if let v = firstCapture(in: rawText, pattern: #"ASN[\s#:]*(?:NO|NUM(?:BER)?)?[\s#:]*([A-Z0-9\-]{4,})"#) {
            data.asnNumber = v
        }

        // SO Number — handles "SO#", "SO:", "SO ", "SO NUMBER", "SALES ORDER"
        if let v = firstCapture(in: rawText, pattern: #"(?:SO|SALES\s*ORDER)[\s#:]*(?:NO|NUM(?:BER)?)?[\s#:]*(\d{4,})"#) {
            data.soNumber = v
        }

        // LOT / Batch number — handles "LOT#", "LOT:", "LOT ", "LOT NUMBER", "BATCH"
        if let v = firstCapture(in: rawText, pattern: #"(?:LOT|BATCH)[\s#:]*(?:NO|NUM(?:BER)?)?[\s#:]*([A-Z0-9\-]{3,})"#) {
            data.lotNumber = v
        }

        // Gross Weight — handles "GW", "GROSS WT", "GROSS WEIGHT" with optional unit
        if let v = firstCapture(in: rawText, pattern: #"(?:GW|G\.?W\.?|GROSS\s*(?:WT|WEIGHT))[\s:]*(\d+\.?\d*\s*(?:kg|lbs?|KG|LBS?)?)"#) {
            data.grossWeight = v
        }

        // Net Weight — handles "NW", "NET WT", "NET WEIGHT" with optional unit
        if let v = firstCapture(in: rawText, pattern: #"(?:NW|N\.?W\.?|NET\s*(?:WT|WEIGHT))[\s:]*(\d+\.?\d*\s*(?:kg|lbs?|KG|LBS?)?)"#) {
            data.netWeight = v
        }

        // Standalone WEIGHT fallback (when no GROSS/NET prefix)
        if data.grossWeight == nil && data.netWeight == nil {
            if let v = firstCapture(in: rawText, pattern: #"WEIGHT[\s:]*(\d+\.?\d*\s*(?:kg|lbs?|KG|LBS?)?)"#) {
                data.grossWeight = v
            }
        }

        // Putaway / Location
        if let v = firstCapture(in: rawText, pattern: #"(?:PUTAWAY|PUT\s*AWAY|LOCATION)[\s:]+(.+?)(?:\n|$)"#) {
            data.putaway = v.trimmingCharacters(in: .whitespaces)
        }

        // Carrier detection
        let carriers = ["UPS", "FEDEX", "DHL", "USPS", "TNT", "MAERSK"]
        for carrier in carriers {
            if fullText.contains(carrier) {
                data.carrier = carrier
                break
            }
        }

        // Tracking number — handles "TRACKING", "TRACKING NO", "TRACKING NUMBER", "TRACK#"
        if let v = firstCapture(in: rawText, pattern: #"(?:TRACK(?:ING)?)[\s#:]*(?:NO|NUM(?:BER)?)?[\s#:]*([A-Z0-9][\w\-]{8,30})"#) {
            data.trackingNumber = v
        } else if let match = rawText.range(of: #"1Z[A-Z0-9]{16}"#, options: .regularExpression) {
            // UPS tracking
            data.trackingNumber = String(rawText[match])
        }

        // Dates (MM/DD/YYYY, YYYY-MM-DD, DD-MMM-YYYY)
        if let v = firstCapture(in: rawText, pattern: #"(?:PACK|MFG|PROD)\s*(?:DATE)?[\s:]*(\d{1,4}[/\-]\d{1,2}[/\-]\d{1,4})"#) {
            data.packDate = v
        }

        // Expiry date
        if let v = firstCapture(in: rawText, pattern: #"(?:EXP(?:IR[YE])?|BEST\s*BY|USE\s*BY)[\s:]*(\d{1,4}[/\-]\d{1,2}[/\-]\d{1,4})"#) {
            data.expiryDate = v
        }

        // Destination — handles "SHIP TO:", "SHIP TO ", "DELIVER TO", "DEST:", "DESTINATION "
        // Supports multi-line addresses by collecting continuation lines.
        for (index, line) in lines.enumerated() {
            if line.localizedCaseInsensitiveContains("ship to") ||
               line.localizedCaseInsensitiveContains("deliver to") ||
               line.localizedCaseInsensitiveContains("dest") {
                var firstLineValue: String? = nil
                // Try colon-separated first
                if let colonRange = line.range(of: ":") {
                    let afterColon = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !afterColon.isEmpty {
                        firstLineValue = afterColon
                    }
                }
                // Fallback: strip the field name keyword and take the rest
                if firstLineValue == nil {
                    let stripped = line
                        .replacingOccurrences(of: #"(?i)(?:SHIP\s*TO|DELIVER\s*TO|DESTINATION|DEST)"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    if !stripped.isEmpty {
                        firstLineValue = stripped
                    }
                }

                guard let baseValue = firstLineValue else { continue }

                // Collect continuation lines
                var parts = [baseValue]
                for nextIdx in (index + 1)..<lines.count {
                    let nextLine = lines[nextIdx].trimmingCharacters(in: .whitespaces)
                    if nextLine.isEmpty || isFieldKeywordLine(nextLine) { break }
                    parts.append(nextLine)
                }
                data.destination = parts.joined(separator: ", ")
                break
            }
        }

        // Handling icons
        var icons: [LabelData.HandlingIcon] = []
        for icon in LabelData.HandlingIcon.allCases {
            if fullText.contains(icon.rawValue) {
                icons.append(icon)
            }
        }
        if !icons.isEmpty {
            data.handlingIcons = icons
        }

        // SKU extraction — handles "SKU#", "SKU:", "SKU ", "ITEM#", "ITEM"
        var skuItems: [LabelData.SKUItem] = []
        let skuPattern = #"(?:SKU|ITEM)[\s#:]*([A-Z0-9\-]{3,})"#
        let skuRegex = try? NSRegularExpression(pattern: skuPattern, options: .caseInsensitive)
        let nsRange = NSRange(rawText.startIndex..., in: rawText)
        if let matches = skuRegex?.matches(in: rawText, range: nsRange) {
            for m in matches {
                if let range = Range(m.range(at: 1), in: rawText) {
                    let sku = String(rawText[range])
                    skuItems.append(LabelData.SKUItem(sku: sku))
                }
            }
        }
        if !skuItems.isEmpty {
            data.skuList = skuItems
        }

        return data
    }

    // MARK: - World Corner Computation

    private func computeWorldCorners(
        rectangle: VNRectangleObservation,
        frame: ARFrame
    ) -> [SIMD3<Float>]? {
        let visionCorners = [
            rectangle.topLeft,
            rectangle.topRight,
            rectangle.bottomRight,
            rectangle.bottomLeft
        ]

        // Depth map unprojection with 5x5 median sampling
        guard let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
            return nil
        }

        let intrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform

        let imageWidth = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageHeight = Float(CVPixelBufferGetHeight(frame.capturedImage))
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPointer = depthBase.assumingMemoryBound(to: Float32.self)
        let depthStride = depthBytesPerRow / MemoryLayout<Float32>.size

        var worldCorners: [SIMD3<Float>] = []

        for vc in visionCorners {
            let camX = Float(vc.y) * imageWidth
            let camY = (1.0 - Float(vc.x)) * imageHeight

            let depthX = Int(camX / imageWidth * Float(depthWidth))
            let depthY = Int(camY / imageHeight * Float(depthHeight))

            guard depthX >= 0, depthX < depthWidth, depthY >= 0, depthY < depthHeight else {
                return nil
            }

            // 5x5 median sampling
            let patchRadius = 2
            var samples: [Float] = []
            for dy in -patchRadius...patchRadius {
                for dx in -patchRadius...patchRadius {
                    let sx = depthX + dx
                    let sy = depthY + dy
                    guard sx >= 0, sx < depthWidth, sy >= 0, sy < depthHeight else { continue }
                    let d = depthPointer[sy * depthStride + sx]
                    if d > 0, d < 10 { samples.append(d) }
                }
            }
            samples.sort()
            guard !samples.isEmpty else { return nil }
            let depth = samples[samples.count / 2]
            guard depth > 0, depth < 10 else { return nil }

            let localX = (camX - cx) * depth / fx
            let localY = (camY - cy) * depth / fy
            let localZ = depth

            let cameraPoint = SIMD4<Float>(localX, -localY, -localZ, 1.0)
            let worldPoint = cameraTransform * cameraPoint
            worldCorners.append(SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z))
        }

#if DEBUG
        print("[LabelReader] World corners from depth map (fallback)")
#endif
        return worldCorners
    }

    // MARK: - Surface Normal

    private func computeSurfaceNormal(corners: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard corners.count >= 3 else { return nil }

        let edge1 = corners[1] - corners[0]
        let edge2 = corners[3] - corners[0]
        let normal = simd_normalize(simd_cross(edge1, edge2))

        guard !normal.x.isNaN else { return nil }
        return normal
    }
}
