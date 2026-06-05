//
//  MeasurementOverlay.swift
//  SnapMeasure
//

import SwiftUI

/// Overlay view for displaying measurement results and controls
struct MeasurementOverlay: View {
    let result: MeasurementCalculator.MeasurementResult?
    let unit: MeasurementUnit
    let isProcessing: Bool
    let trackingMessage: String

    var onSave: () -> Void
    var onEdit: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        VStack {
            // Top status area
            topStatusView

            Spacer()

            // Bottom measurement card
            if let result = result {
                bottomMeasurementCard(result: result)
            } else if isProcessing {
                processingIndicator
            } else {
                instructionView
            }
        }
        .padding()
    }

    // MARK: - Subviews

    private var topStatusView: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
            Text(trackingMessage)
                .foregroundColor(.white)
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
    }

    private var statusIcon: String {
        if isProcessing {
            return "arrow.triangle.2.circlepath"
        } else if trackingMessage == "Ready to measure" {
            return "checkmark.circle.fill"
        } else if trackingMessage.contains("not") {
            return "exclamationmark.triangle.fill"
        } else {
            return "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        if trackingMessage == "Ready to measure" {
            return .green
        } else if trackingMessage.contains("not") {
            return .red
        } else {
            return .yellow
        }
    }

    private var processingIndicator: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
            Text("Measuring...")
                .foregroundColor(.white)
                .font(.headline)
        }
        .padding(24)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var instructionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 36))
                .foregroundColor(.white)

            Text("Tap to Measure")
                .font(.headline)
                .foregroundColor(.white)

            Text("Point at an object and tap to measure its dimensions")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func bottomMeasurementCard(result: MeasurementCalculator.MeasurementResult) -> some View {
        VStack(spacing: 16) {
            // Quality badge
            HStack {
                qualityBadge(quality: result.quality.overallQuality)
                Spacer()
            }

            // Dimensions display
            dimensionsDisplay(result: result)

            // Volume display
            volumeDisplay(result: result)

            // Action buttons
            actionButtons
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func qualityBadge(quality: QualityLevel) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(qualityColor(quality))
                .frame(width: 10, height: 10)

            Text(quality.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
        .clipShape(Capsule())
    }

    private func qualityColor(_ quality: QualityLevel) -> Color {
        switch quality {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .red
        }
    }

    private func dimensionsDisplay(result: MeasurementCalculator.MeasurementResult) -> some View {
        HStack(spacing: 20) {
            dimensionItem(label: "Length", value: result.length)
            dimensionItem(label: "Width", value: result.width)
            dimensionItem(label: "Height", value: result.height)
        }
    }

    private func dimensionItem(label: LocalizedStringKey, value: Float) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(formatDimension(value))
                .font(.title2)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
    }

    private func volumeDisplay(result: MeasurementCalculator.MeasurementResult) -> some View {
        HStack {
            Text("Volume")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Text(formatVolume(result.volume))
                .font(.headline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: onDiscard) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)

            Button(action: onSave) {
                HStack {
                    Image(systemName: "checkmark")
                    Text("Save")
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Formatting

    private func formatDimension(_ meters: Float) -> String {
        let value = unit.convert(meters: meters)
        if value >= 100 {
            return String(format: "%.0f %@", value, unit.rawValue)
        } else if value >= 10 {
            return String(format: "%.1f %@", value, unit.rawValue)
        } else {
            return String(format: "%.2f %@", value, unit.rawValue)
        }
    }

    private func formatVolume(_ cubicMeters: Float) -> String {
        let value = unit.convertVolume(cubicMeters: cubicMeters)
        if value >= 1000 {
            return String(format: "%.0f %@", value, unit.volumeUnit())
        } else if value >= 100 {
            return String(format: "%.1f %@", value, unit.volumeUnit())
        } else {
            return String(format: "%.2f %@", value, unit.volumeUnit())
        }
    }
}

#Preview {
    ZStack {
        Color.gray
            .ignoresSafeArea()

        MeasurementOverlay(
            result: nil,
            unit: .centimeters,
            isProcessing: false,
            trackingMessage: "Ready to measure",
            onSave: {},
            onEdit: {},
            onDiscard: {}
        )
    }
}
