//
//  ARMeasurementHelperViews.swift
//  SnapMeasure
//

import SwiftUI

// MARK: - Status Bar

struct StatusBar: View {
    let trackingMessage: String
    let isProcessing: Bool
    var isTrackingReady: Bool = false
    var isTrackingError: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if isProcessing {
                ScanningIndicator()
                    .frame(width: 18, height: 18)
                Text("Processing...")
                    .font(PMTheme.mono(13))
                    .foregroundColor(PMTheme.textPrimary)
            } else {
                Image(systemName: trackingStatusIcon)
                    .foregroundColor(trackingStatusColor)
                    .symbolEffect(.pulse, options: .repeating, value: isTrackingReady)
                Text(trackingMessage)
                    .font(PMTheme.mono(13))
                    .foregroundColor(PMTheme.textPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PMTheme.surfaceDark.opacity(0.85))
        .overlay(
            Capsule()
                .strokeBorder(PMTheme.cyan.opacity(0.30), lineWidth: 0.5)
        )
        .clipShape(Capsule())
    }

    private var trackingStatusIcon: String {
        if isTrackingReady {
            return "checkmark.circle.fill"
        } else if isTrackingError {
            return "exclamationmark.triangle.fill"
        } else {
            return "arrow.triangle.2.circlepath"
        }
    }

    private var trackingStatusColor: Color {
        if isTrackingReady {
            return PMTheme.green
        } else if isTrackingError {
            return PMTheme.red
        } else {
            return PMTheme.amber
        }
    }
}

// MARK: - Scanning Indicator

struct ScanningIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(PMTheme.cyan.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(PMTheme.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(rotation))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Instruction Card

struct InstructionCard: View {
    enum Mode: Equatable {
        case tap, box, refine, secondTap, label, confirm
        case holdSteady, scanAround
        case processing
        case ready(String)  // tracking message
        case refinementFailed(String)
    }

    var mode: Mode = .tap
    var isTrackingReady: Bool = false
    var isTrackingError: Bool = false

    private var isProcessing: Bool {
        if case .processing = mode { return true }
        return false
    }

    private var iconName: String {
        switch mode {
        case .tap: return "hand.tap.fill"
        case .box: return "rectangle.dashed"
        case .refine: return "arrow.triangle.2.circlepath"
        case .secondTap: return "arrow.triangle.2.circlepath"
        case .label: return "doc.text.viewfinder"
        case .confirm: return "checkmark.circle.fill"
        case .holdSteady: return "hand.raised.fill"
        case .scanAround: return "arrow.triangle.2.circlepath.camera"
        case .processing: return "circle.dotted"
        case .refinementFailed: return "exclamationmark.triangle.fill"
        case .ready:
            if isTrackingReady { return "checkmark.circle.fill" }
            else if isTrackingError { return "exclamationmark.triangle.fill" }
            else { return "arrow.triangle.2.circlepath" }
        }
    }

    private var title: String {
        switch mode {
        case .tap: return String(localized: "Center the object on screen")
        case .box: return String(localized: "Draw a box to select")
        case .refine: return String(localized: "Refine from a different angle")
        case .secondTap: return String(localized: "Tap again from a different angle")
        case .label: return String(localized: "Point at a label and tap")
        case .confirm: return String(localized: "Tap to confirm measurement")
        case .holdSteady: return String(localized: "Hold steady — detecting object")
        case .scanAround: return String(localized: "Scan from different angles for accuracy")
        case .processing: return String(localized: "Processing...")
        case .refinementFailed(let msg): return msg
        case .ready(let msg): return msg
        }
    }

    private var isLabelMode: Bool { mode == .label }

    private var accentColor: Color {
        if isLabelMode { return PMTheme.labelBlue }
        if case .refinementFailed = mode { return PMTheme.amber }
        if case .ready = mode {
            if isTrackingReady { return PMTheme.green }
            else if isTrackingError { return PMTheme.red }
            else { return PMTheme.amber }
        }
        return PMTheme.cyan
    }

    var body: some View {
        HStack(spacing: 8) {
            if isProcessing {
                ScanningIndicator()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundColor(accentColor)
                    .symbolEffect(.pulse, options: .repeating, value: isReadyPulse)
            }

            Text(title)
                .font(PMTheme.mono(13))
                .foregroundColor(PMTheme.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PMTheme.surfaceDark.opacity(0.85))
        .overlay(
            Capsule()
                .strokeBorder(accentColor.opacity(0.30), lineWidth: 0.5)
        )
        .clipShape(Capsule())
    }

    private var isReadyPulse: Bool {
        if case .ready = mode { return isTrackingReady }
        return false
    }
}

// MARK: - LiDAR Not Available View

struct LiDARNotAvailableView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                Image(systemName: "sensor.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)

                Text("LiDAR Not Available")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("This app requires a LiDAR sensor for 3D measurements. Please use one of the following devices:")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 16) {
                    DeviceGroupView(
                        title: String(localized: "iPhone"),
                        devices: [
                            "iPhone 12 Pro / Pro Max",
                            "iPhone 13 Pro / Pro Max",
                            "iPhone 14 Pro / Pro Max",
                            "iPhone 15 Pro / Pro Max",
                            "iPhone 16 Pro / Pro Max",
                        ]
                    )
                    DeviceGroupView(
                        title: String(localized: "iPad"),
                        devices: [
                            "iPad Pro 11\" (2nd gen〜)",
                            "iPad Pro 12.9\" (4th gen〜)",
                        ]
                    )
                }
                .padding(.horizontal, 32)
            }
            .padding()
        }
    }
}

private struct DeviceGroupView: View {
    let title: String
    let devices: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ForEach(devices, id: \.self) { device in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text(device)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
