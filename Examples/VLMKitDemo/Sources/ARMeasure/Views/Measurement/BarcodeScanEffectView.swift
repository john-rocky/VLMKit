//
//  BarcodeScanEffectView.swift
//  SnapMeasure
//

import SwiftUI

/// Targeted barcode/text scan effect overlay.
/// A scanline sweeps through the label area, highlighting text lines as it passes
/// and framing detected barcodes with soft neon green highlights.
struct BarcodeScanEffectView: View {
    let labelData: LabelData
    let labelImageSize: CGSize
    let labelImage: UIImage?
    let onComplete: () -> Void

    // MARK: - Animation State

    @State private var phase: ScanPhase = .idle
    @State private var scanlineProgress: CGFloat = -0.02  // 0 = top, 1 = bottom
    @State private var textLineOpacities: [Double] = []
    @State private var barcodeHighlightOpacities: [Double] = []
    @State private var barcodePulseScale: CGFloat = 1.0
    @State private var statusText: String = String(localized: "SCANNING...")
    @State private var statusOpacity: Double = 0
    @State private var flashOpacity: Double = 0
    @State private var overallOpacity: Double = 1.0

    private enum ScanPhase {
        case idle, scanning, detected, fading
    }

    /// Fill fraction matching LabelLiftAnimation's 85% placement
    private let fillFraction: CGFloat = 0.85

    var body: some View {
        GeometryReader { geometry in
            let labelRect = labelDisplayRect(in: geometry.size)

            ZStack {
                // 2D label image behind highlights
                if let uiImage = labelImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .frame(width: labelRect.width, height: labelRect.height)
                        .position(x: labelRect.midX, y: labelRect.midY)
                        .opacity(overallOpacity)
                }

                // Text line highlights
                textLineHighlights(labelRect: labelRect)
                    .opacity(overallOpacity)

                // Barcode region highlights
                barcodeHighlights(labelRect: labelRect)
                    .opacity(overallOpacity)

                // Scanline
                if phase == .scanning {
                    scanline(width: geometry.size.width, labelRect: labelRect)
                        .opacity(overallOpacity)
                }

                // Flash overlay
                Rectangle()
                    .fill(PMTheme.labelBlue)
                    .opacity(flashOpacity)
                    .ignoresSafeArea()

                // Status pill
                statusPill
                    .opacity(statusOpacity * overallOpacity)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.85)
            }
        }
        .onAppear {
            initializeState()
            startAnimation()
        }
    }

    // MARK: - Layout

    /// Compute screen rect matching where LabelLiftAnimation places the label:
    /// fills 85% of the screen while preserving the corrected image's aspect ratio.
    private func labelDisplayRect(in size: CGSize) -> CGRect {
        guard labelImageSize.width > 0, labelImageSize.height > 0 else {
            // Fallback: centered square-ish area
            let inset: CGFloat = 0.08
            return CGRect(
                x: size.width * inset, y: size.height * inset,
                width: size.width * (1 - 2 * inset), height: size.height * (1 - 2 * inset)
            )
        }

        let imageAspect = labelImageSize.width / labelImageSize.height
        let screenAspect = size.width / size.height

        let w: CGFloat
        let h: CGFloat

        if imageAspect > screenAspect {
            // Width-limited (label is wider relative to screen)
            w = size.width * fillFraction
            h = w / imageAspect
        } else {
            // Height-limited
            h = size.height * fillFraction
            w = h * imageAspect
        }

        return CGRect(
            x: (size.width - w) / 2,
            y: (size.height - h) / 2,
            width: w,
            height: h
        )
    }

    /// Convert Vision normalized coords (bottom-left origin) to screen coords (top-left origin)
    private func visionToScreen(_ visionRect: CGRect, in labelRect: CGRect) -> CGRect {
        let x = labelRect.minX + visionRect.minX * labelRect.width
        let y = labelRect.minY + (1 - visionRect.maxY) * labelRect.height
        let w = visionRect.width * labelRect.width
        let h = visionRect.height * labelRect.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Normalized Y position (0=top, 1=bottom) for a Vision bounding box center
    private func normalizedY(for visionRect: CGRect) -> CGFloat {
        1 - (visionRect.midY)
    }

    // MARK: - Scanline

    @ViewBuilder
    private func scanline(width: CGFloat, labelRect: CGRect) -> some View {
        let yPos = labelRect.minY + scanlineProgress * labelRect.height
        VStack(spacing: 0) {
            LinearGradient(
                colors: [PMTheme.labelBlue.opacity(0), PMTheme.labelBlue.opacity(0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: width, height: 20)

            Rectangle()
                .fill(PMTheme.labelBlue)
                .frame(width: width, height: 1.5)
                .shadow(color: PMTheme.labelBlue.opacity(0.7), radius: 8, x: 0, y: 0)

            LinearGradient(
                colors: [PMTheme.labelBlue.opacity(0.12), PMTheme.labelBlue.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: width, height: 20)
        }
        .position(x: width / 2, y: yPos)
    }

    // MARK: - Text Line Highlights

    @ViewBuilder
    private func textLineHighlights(labelRect: CGRect) -> some View {
        if let bounds = labelData.textLineBounds, !bounds.isEmpty {
            ForEach(0..<bounds.count, id: \.self) { i in
                let screenRect = visionToScreen(bounds[i], in: labelRect)
                RoundedRectangle(cornerRadius: 2)
                    .fill(PMTheme.labelBlue.opacity(0.15))
                    .frame(width: screenRect.width + 4, height: screenRect.height + 2)
                    .position(x: screenRect.midX, y: screenRect.midY)
                    .opacity(i < textLineOpacities.count ? textLineOpacities[i] : 0)
            }
        }
    }

    // MARK: - Barcode Highlights

    @ViewBuilder
    private func barcodeHighlights(labelRect: CGRect) -> some View {
        if let barcodes = labelData.barcodes {
            ForEach(0..<barcodes.count, id: \.self) { i in
                if let box = barcodes[i].boundingBox {
                    let screenRect = visionToScreen(box, in: labelRect)
                    ZStack {
                        // Soft fill
                        RoundedRectangle(cornerRadius: 4)
                            .fill(PMTheme.labelBlue.opacity(0.08))
                            .frame(width: screenRect.width + 8, height: screenRect.height + 8)

                        // Border frame
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(PMTheme.labelBlue.opacity(0.6), lineWidth: 1.5)
                            .frame(width: screenRect.width + 8, height: screenRect.height + 8)
                    }
                    .scaleEffect(barcodePulseScale)
                    .position(x: screenRect.midX, y: screenRect.midY)
                    .opacity(i < barcodeHighlightOpacities.count ? barcodeHighlightOpacities[i] : 0)
                }
            }
        }
    }

    // MARK: - Status Pill

    private var statusPill: some View {
        HStack(spacing: 4) {
            Text(statusText)
                .font(PMTheme.mono(13, weight: .bold))
                .foregroundColor(phase == .detected ? PMTheme.labelBlue : .white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.7))
                .overlay(
                    Capsule()
                        .stroke(
                            phase == .detected ? PMTheme.labelBlue : Color.white.opacity(0.3),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - State Init

    private func initializeState() {
        let textCount = labelData.textLineBounds?.count ?? 0
        textLineOpacities = Array(repeating: 0.0, count: textCount)

        let barcodeCount = labelData.barcodes?.count ?? 0
        barcodeHighlightOpacities = Array(repeating: 0.0, count: barcodeCount)
    }

    // MARK: - Animation Orchestration

    private func startAnimation() {
        phase = .scanning

        let scanDuration = PMTheme.barcodeScanDetectTime  // 1.2s for scan phase

        // Show status pill
        withAnimation(.easeOut(duration: 0.2)) {
            statusOpacity = 1.0
        }

        // Animate scanline from top to bottom
        withAnimation(.easeInOut(duration: scanDuration)) {
            scanlineProgress = 1.02
        }

        // Schedule text line highlights as scanline passes each line
        scheduleTextHighlights(scanDuration: scanDuration)

        // Schedule barcode highlights as scanline passes each barcode
        scheduleBarcodeHighlights(scanDuration: scanDuration)

        // Phase 2: DETECT (1.2s – 1.6s)
        DispatchQueue.main.asyncAfter(deadline: .now() + PMTheme.barcodeScanDetectTime) {
            phase = .detected

            let barcodeCount = labelData.barcodes?.count ?? 0
            withAnimation(.easeOut(duration: 0.1)) {
                statusText = barcodeCount > 0
                    ? String(localized: "\(barcodeCount) BARCODE(S) DETECTED")
                    : String(localized: "DETECTED")
            }

            // Flash barcode highlights bright
            for i in 0..<barcodeHighlightOpacities.count {
                withAnimation(.easeOut(duration: 0.15)) {
                    barcodeHighlightOpacities[i] = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        barcodeHighlightOpacities[i] = 0.7
                    }
                }
            }

            // Green flash
            withAnimation(.easeOut(duration: 0.08)) {
                flashOpacity = 0.15
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeOut(duration: 0.15)) {
                    flashOpacity = 0
                }
            }

            // Gentle barcode pulse
            withAnimation(.easeInOut(duration: 0.3).repeatCount(2, autoreverses: true)) {
                barcodePulseScale = 1.04
            }
        }

        // Phase 3: FADE (1.6s – 2.0s)
        DispatchQueue.main.asyncAfter(deadline: .now() + PMTheme.barcodeScanFadeTime) {
            phase = .fading
            withAnimation(.easeIn(duration: PMTheme.barcodeScanDuration - PMTheme.barcodeScanFadeTime)) {
                overallOpacity = 0
                statusOpacity = 0
            }
        }

        // Completion
        DispatchQueue.main.asyncAfter(deadline: .now() + PMTheme.barcodeScanDuration) {
            onComplete()
        }
    }

    // MARK: - Highlight Scheduling

    private func scheduleTextHighlights(scanDuration: Double) {
        guard let bounds = labelData.textLineBounds, !bounds.isEmpty else { return }

        for (i, rect) in bounds.enumerated() {
            let normY = normalizedY(for: rect)
            let triggerTime = Double(normY) * scanDuration

            // Fade in
            DispatchQueue.main.asyncAfter(deadline: .now() + triggerTime) {
                guard i < textLineOpacities.count else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    textLineOpacities[i] = 1.0
                }
            }

            // Hold then fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + triggerTime + 0.3) {
                guard i < textLineOpacities.count else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    textLineOpacities[i] = 0
                }
            }
        }
    }

    private func scheduleBarcodeHighlights(scanDuration: Double) {
        guard let barcodes = labelData.barcodes else { return }

        for (i, item) in barcodes.enumerated() {
            guard let box = item.boundingBox else { continue }
            let normY = normalizedY(for: box)
            let triggerTime = Double(normY) * scanDuration

            // Fade in when scanline reaches barcode
            DispatchQueue.main.asyncAfter(deadline: .now() + triggerTime) {
                guard i < barcodeHighlightOpacities.count else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    barcodeHighlightOpacities[i] = 0.8
                }
            }
            // Barcode highlights persist (no fade out until Phase 3)
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        BarcodeScanEffectView(
            labelData: LabelData(
                barcodes: [
                    .init(value: "12345", symbology: "EAN13", boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.15))
                ],
                rawText: "Sample label text",
                textLineBounds: [
                    CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.05),
                    CGRect(x: 0.1, y: 0.6, width: 0.7, height: 0.05),
                    CGRect(x: 0.1, y: 0.5, width: 0.75, height: 0.05),
                    CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.05)
                ]
            ),
            labelImageSize: CGSize(width: 400, height: 300),
            labelImage: nil,
            onComplete: {}
        )
    }
}
