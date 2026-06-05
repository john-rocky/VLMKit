//
//  LabelData.swift
//  SnapMeasure
//

import Foundation

struct LabelData: Codable {
    var cartonId: String?
    var barcodes: [BarcodeItem]?
    var destination: String?
    var poNumber: String?
    var asnNumber: String?
    var soNumber: String?
    var skuList: [SKUItem]?
    var lotNumber: String?
    var packDate: String?
    var grossWeight: String?
    var netWeight: String?
    var carrier: String?
    var trackingNumber: String?
    var handlingIcons: [HandlingIcon]?
    var expiryDate: String?
    var contents: String?
    var dimensions: String?
    var putaway: String?
    var handling: String?
    var rawText: String

    var textLineBounds: [CGRect]?  // Per-line bounding boxes (Vision normalized, bottom-left origin)

    struct BarcodeItem: Codable {
        var value: String
        var symbology: String?
        var boundingBox: CGRect?  // Vision normalized (0-1, bottom-left origin)
    }

    struct SKUItem: Codable {
        var sku: String?
        var productName: String?
        var quantity: String?
    }

    enum HandlingIcon: String, Codable, CaseIterable {
        case fragile = "FRAGILE"
        case thisSideUp = "THIS SIDE UP"
        case keepDry = "KEEP DRY"
        case doNotDrop = "DO NOT DROP"
        case lithiumBattery = "LITHIUM BATTERY"
    }

    // Backward-compatible decoding: migrates old barcodeValue/barcodeSymbology
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cartonId = try container.decodeIfPresent(String.self, forKey: .cartonId)
        barcodes = try container.decodeIfPresent([BarcodeItem].self, forKey: .barcodes)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        poNumber = try container.decodeIfPresent(String.self, forKey: .poNumber)
        asnNumber = try container.decodeIfPresent(String.self, forKey: .asnNumber)
        soNumber = try container.decodeIfPresent(String.self, forKey: .soNumber)
        skuList = try container.decodeIfPresent([SKUItem].self, forKey: .skuList)
        lotNumber = try container.decodeIfPresent(String.self, forKey: .lotNumber)
        packDate = try container.decodeIfPresent(String.self, forKey: .packDate)
        grossWeight = try container.decodeIfPresent(String.self, forKey: .grossWeight)
        netWeight = try container.decodeIfPresent(String.self, forKey: .netWeight)
        carrier = try container.decodeIfPresent(String.self, forKey: .carrier)
        trackingNumber = try container.decodeIfPresent(String.self, forKey: .trackingNumber)
        handlingIcons = try container.decodeIfPresent([HandlingIcon].self, forKey: .handlingIcons)
        expiryDate = try container.decodeIfPresent(String.self, forKey: .expiryDate)
        contents = try container.decodeIfPresent(String.self, forKey: .contents)
        dimensions = try container.decodeIfPresent(String.self, forKey: .dimensions)
        putaway = try container.decodeIfPresent(String.self, forKey: .putaway)
        handling = try container.decodeIfPresent(String.self, forKey: .handling)
        rawText = try container.decode(String.self, forKey: .rawText)
        textLineBounds = try container.decodeIfPresent([CGRect].self, forKey: .textLineBounds)

        // Migrate legacy single-barcode fields
        if barcodes == nil,
           let oldValue = try container.decodeIfPresent(String.self, forKey: .barcodeValue) {
            let oldSym = try container.decodeIfPresent(String.self, forKey: .barcodeSymbology)
            barcodes = [BarcodeItem(value: oldValue, symbology: oldSym)]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case cartonId, barcodes, destination, poNumber, asnNumber, soNumber
        case skuList, lotNumber, packDate, grossWeight, netWeight
        case carrier, trackingNumber, handlingIcons, expiryDate
        case contents, dimensions, putaway, handling, rawText
        case textLineBounds
        case barcodeValue, barcodeSymbology  // legacy keys for decoding only
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(cartonId, forKey: .cartonId)
        try container.encodeIfPresent(barcodes, forKey: .barcodes)
        try container.encodeIfPresent(destination, forKey: .destination)
        try container.encodeIfPresent(poNumber, forKey: .poNumber)
        try container.encodeIfPresent(asnNumber, forKey: .asnNumber)
        try container.encodeIfPresent(soNumber, forKey: .soNumber)
        try container.encodeIfPresent(skuList, forKey: .skuList)
        try container.encodeIfPresent(lotNumber, forKey: .lotNumber)
        try container.encodeIfPresent(packDate, forKey: .packDate)
        try container.encodeIfPresent(grossWeight, forKey: .grossWeight)
        try container.encodeIfPresent(netWeight, forKey: .netWeight)
        try container.encodeIfPresent(carrier, forKey: .carrier)
        try container.encodeIfPresent(trackingNumber, forKey: .trackingNumber)
        try container.encodeIfPresent(handlingIcons, forKey: .handlingIcons)
        try container.encodeIfPresent(expiryDate, forKey: .expiryDate)
        try container.encodeIfPresent(contents, forKey: .contents)
        try container.encodeIfPresent(dimensions, forKey: .dimensions)
        try container.encodeIfPresent(putaway, forKey: .putaway)
        try container.encodeIfPresent(handling, forKey: .handling)
        try container.encode(rawText, forKey: .rawText)
        try container.encodeIfPresent(textLineBounds, forKey: .textLineBounds)
    }

    init(
        cartonId: String? = nil, barcodes: [BarcodeItem]? = nil,
        destination: String? = nil, poNumber: String? = nil,
        asnNumber: String? = nil, soNumber: String? = nil,
        skuList: [SKUItem]? = nil, lotNumber: String? = nil,
        packDate: String? = nil, grossWeight: String? = nil,
        netWeight: String? = nil, carrier: String? = nil,
        trackingNumber: String? = nil, handlingIcons: [HandlingIcon]? = nil,
        expiryDate: String? = nil, contents: String? = nil,
        dimensions: String? = nil, putaway: String? = nil,
        handling: String? = nil, rawText: String,
        textLineBounds: [CGRect]? = nil
    ) {
        self.cartonId = cartonId
        self.barcodes = barcodes
        self.destination = destination
        self.poNumber = poNumber
        self.asnNumber = asnNumber
        self.soNumber = soNumber
        self.skuList = skuList
        self.lotNumber = lotNumber
        self.packDate = packDate
        self.grossWeight = grossWeight
        self.netWeight = netWeight
        self.carrier = carrier
        self.trackingNumber = trackingNumber
        self.handlingIcons = handlingIcons
        self.expiryDate = expiryDate
        self.contents = contents
        self.dimensions = dimensions
        self.putaway = putaway
        self.handling = handling
        self.rawText = rawText
        self.textLineBounds = textLineBounds
    }

    /// Labels considered primary (shown large at top)
    private static let primaryLabels: Set<String> = ["CTN ID", "BARCODE", "DEST"]

    /// Whether a label is primary (matches exact name or "BARCODE N" pattern)
    private static func isPrimary(_ label: String) -> Bool {
        primaryLabels.contains(label) || label.hasPrefix("BARCODE ")
    }

    /// Primary display fields (CTN ID, BARCODE(s), DEST)
    var primaryDisplayFields: [(icon: String, label: String, value: String)] {
        displayFields.filter { Self.isPrimary($0.label) }
    }

    /// Secondary display fields (everything except primary)
    var secondaryDisplayFields: [(icon: String, label: String, value: String)] {
        displayFields.filter { !Self.isPrimary($0.label) }
    }

    /// Returns non-nil fields as display pairs (label, value)
    var displayFields: [(icon: String, label: String, value: String)] {
        var fields: [(String, String, String)] = []

        if let v = cartonId { fields.append(("shippingbox.fill", "CTN ID", v)) }
        if let codes = barcodes {
            for (i, item) in codes.enumerated() {
                let sym = item.symbology.map { " (\($0))" } ?? ""
                let label = codes.count == 1 ? "BARCODE" : "BARCODE \(i + 1)"
                fields.append(("barcode", label, item.value + sym))
            }
        }
        if let v = destination { fields.append(("mappin.and.ellipse", "DEST", v)) }
        if let v = putaway { fields.append(("square.grid.3x3", "PUTAWAY", v)) }
        if let v = poNumber { fields.append(("doc.text", "PO#", v)) }
        if let v = asnNumber { fields.append(("doc.plaintext", "ASN", v)) }
        if let v = lotNumber { fields.append(("number.circle", "LOT", v)) }
        if let v = contents { fields.append(("shippingbox", "CONTENTS", v)) }
        if let v = packDate { fields.append(("calendar", "DATE", v)) }
        if let v = grossWeight { fields.append(("scalemass", "GW", v)) }
        if let v = netWeight { fields.append(("scalemass.fill", "NW", v)) }
        if let v = dimensions { fields.append(("ruler", "DIMS", v)) }
        if let v = carrier { fields.append(("truck.box", "CARRIER", v)) }
        if let v = trackingNumber { fields.append(("number", "TRACK#", v)) }
        if let v = expiryDate { fields.append(("clock.badge.exclamationmark", "EXPIRY", v)) }

        if let v = handling {
            fields.append(("exclamationmark.triangle", "HANDLING", v))
        } else if let icons = handlingIcons, !icons.isEmpty {
            fields.append(("exclamationmark.triangle", "HANDLING", icons.map(\.rawValue).joined(separator: ", ")))
        }

        if let skus = skuList, !skus.isEmpty {
            for (i, item) in skus.enumerated() {
                let parts = [item.sku, item.productName, item.quantity].compactMap { $0 }
                fields.append(("cube.box", "SKU \(i + 1)", parts.joined(separator: " / ")))
            }
        }

        return fields
    }

    /// Whether any OCR-parsed structured fields (excluding barcode) are present
    var hasOCRFields: Bool {
        cartonId != nil || destination != nil || poNumber != nil ||
        asnNumber != nil || soNumber != nil || lotNumber != nil ||
        packDate != nil || grossWeight != nil || netWeight != nil ||
        carrier != nil || trackingNumber != nil || expiryDate != nil ||
        handlingIcons != nil || skuList != nil ||
        contents != nil || dimensions != nil || putaway != nil || handling != nil
    }
}
