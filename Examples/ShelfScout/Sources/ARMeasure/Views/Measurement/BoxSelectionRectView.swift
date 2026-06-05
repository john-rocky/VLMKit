//
//  BoxSelectionRectView.swift
//  SnapMeasure
//

import UIKit

/// UIKit view that draws box selection visuals (dim overlay, selection rect, status label).
/// Has `isUserInteractionEnabled = false` so it never captures touches.
class BoxSelectionRectView: UIView {

    /// The current selection rectangle in the parent view's coordinate space.
    var selectionRect: CGRect? {
        didSet { setNeedsDisplay() }
    }

    /// Whether the current rectangle meets the minimum size requirement.
    var isRectValid: Bool = false {
        didSet { updateStatusLabel() }
    }

    // Minimum selection size (points)
    static let minimumSize: CGFloat = 50

    // Theme colors
    private let cyanColor = PMTheme.uiCyan
    private let greenColor = PMTheme.uiGreen
    private let amberColor = PMTheme.uiAmber

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.textAlignment = .center
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.isHidden = true
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        addSubview(statusLabel)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let selRect = selectionRect else {
            return
        }

        // Dim overlay (black 0.3) with cutout for selection
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.3).cgColor)
        ctx.fill(bounds)
        ctx.clear(selRect)

        // Selection rectangle fill (cyan glow)
        ctx.setFillColor(cyanColor.withAlphaComponent(0.15).cgColor)
        ctx.fill(selRect)

        // Selection rectangle border (cyan)
        ctx.setStrokeColor(cyanColor.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(selRect)

        // Position status label below the rect
        statusLabel.sizeToFit()
        let labelWidth = statusLabel.intrinsicContentSize.width + 16
        let labelHeight: CGFloat = 24
        statusLabel.frame = CGRect(
            x: selRect.midX - labelWidth / 2,
            y: selRect.maxY + 8,
            width: labelWidth,
            height: labelHeight
        )
        statusLabel.isHidden = false
    }

    private func updateStatusLabel() {
        if isRectValid {
            statusLabel.text = String(localized: "Release to select")
            statusLabel.backgroundColor = greenColor.withAlphaComponent(0.8)
        } else {
            statusLabel.text = String(localized: "Make it bigger")
            statusLabel.backgroundColor = amberColor.withAlphaComponent(0.8)
        }
    }

    /// Clear the selection visuals.
    func clearSelection() {
        selectionRect = nil
        isRectValid = false
        statusLabel.isHidden = true
        setNeedsDisplay()
    }
}
