//
//  PipelineDiagnosticsView.swift
//  SnapMeasure
//

#if DEBUG
import SwiftUI

struct PipelineDiagnosticsView: View {
    let diagnostics: PipelineDiagnostics
    var pointCloudCapture: PipelinePointCloudCapture?
    @Binding var selectedStage: PipelinePointCloudCapture.Stage?
    var onStageSelected: ((PipelinePointCloudCapture.Stage?) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var expandedStages: Set<String> = []

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headerSection
                    if let failedStage = diagnostics.failedAtStage {
                        failureBanner(stage: failedStage, reason: diagnostics.failureReason ?? "Unknown")
                    }
                    stageList

                    if let capture = pointCloudCapture {
                        let _ = print("[DiagView] Showing 3D section, stages: \(PipelinePointCloudCapture.Stage.allCases.map { "\($0.displayName)=\(capture.keptCount(at: $0))" }), onStageSelected=\(onStageSelected != nil)")
                        pointCloudSection
                    } else {
                        let _ = print("[DiagView] pointCloudCapture is nil, hiding 3D section")
                    }
                }
                .padding()
            }
            .background(PMTheme.surfaceDark.ignoresSafeArea())
            .navigationTitle("Pipeline Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(PMTheme.cyan)
                }
            }
            .toolbarBackground(PMTheme.surfaceDark, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pipeline: \(diagnostics.pipelineVersion)")
                    .font(PMTheme.mono(13, weight: .bold))
                    .foregroundColor(PMTheme.textPrimary)
                Spacer()
                Text(String(format: "%.0fms", diagnostics.overallDurationMs))
                    .font(PMTheme.mono(13))
                    .foregroundColor(PMTheme.textSecondary)
            }
            HStack {
                Circle()
                    .fill(diagnostics.succeeded ? PMTheme.green : PMTheme.red)
                    .frame(width: 8, height: 8)
                Text(diagnostics.succeeded ? "SUCCESS" : "FAILED")
                    .font(PMTheme.mono(11, weight: .bold))
                    .foregroundColor(diagnostics.succeeded ? PMTheme.green : PMTheme.red)
            }
        }
        .padding(12)
        .background(PMTheme.surfaceCard)
        .cornerRadius(8)
    }

    // MARK: - Failure Banner

    private func failureBanner(stage: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FAILED AT: \(stage)")
                .font(PMTheme.mono(12, weight: .bold))
                .foregroundColor(.white)
            Text(reason)
                .font(PMTheme.mono(11))
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(PMTheme.red.opacity(0.85))
        .cornerRadius(8)
    }

    // MARK: - Stage List

    private var stageList: some View {
        VStack(spacing: 2) {
            ForEach(diagnostics.stages, id: \.name) { stage in
                stageRow(name: stage.name, status: stage.status, summary: stage.summary)
            }
        }
    }

    private func stageRow(name: String, status: PipelineDiagnostics.StageStatus, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedStages.contains(name) {
                        expandedStages.remove(name)
                    } else {
                        expandedStages.insert(name)
                    }
                }
            }) {
                HStack(alignment: .top, spacing: 8) {
                    Text(status.emoji)
                        .font(.system(size: 10))
                        .foregroundColor(statusColor(status))
                        .frame(width: 14, alignment: .center)
                        .padding(.top, 3)

                    Text(name)
                        .font(PMTheme.mono(11, weight: .bold))
                        .foregroundColor(PMTheme.textPrimary)
                        .frame(width: 110, alignment: .leading)

                    Text(summary)
                        .font(PMTheme.mono(10))
                        .foregroundColor(PMTheme.textSecondary)
                        .lineLimit(expandedStages.contains(name) ? nil : 1)

                    Spacer()

                    Image(systemName: expandedStages.contains(name) ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(PMTheme.textDimmed)
                        .padding(.top, 3)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)

            if expandedStages.contains(name) {
                expandedDetail(for: name)
                    .padding(.leading, 32)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(PMTheme.surfaceCard)
        .cornerRadius(4)
    }

    // MARK: - 3D Point Cloud Visualization

    private var pointCloudSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3D POINT CLOUD")
                .font(PMTheme.mono(11, weight: .bold))
                .foregroundColor(PMTheme.cyan)
                .padding(.top, 8)

            VStack(spacing: 2) {
                ForEach(PipelinePointCloudCapture.Stage.allCases, id: \.rawValue) { stage in
                    pointCloudStageButton(stage: stage)
                }
            }

            if selectedStage != nil {
                Button(action: {
                    selectedStage = nil
                    onStageSelected?(nil)
                }) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                        Text("CLEAR")
                            .font(PMTheme.mono(11, weight: .bold))
                    }
                    .foregroundColor(PMTheme.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(PMTheme.red.opacity(0.15))
                    .cornerRadius(6)
                }
                .padding(.top, 4)
            }
        }
    }

    private func pointCloudStageButton(stage: PipelinePointCloudCapture.Stage) -> some View {
        let kept = pointCloudCapture?.keptCount(at: stage) ?? 0
        let removed = pointCloudCapture?.removedCount(at: stage) ?? 0
        let isSelected = selectedStage == stage
        let hasData = kept > 0

        return Button {
            print("[DiagView] Button tapped: \(stage.displayName), hasData=\(hasData), onStageSelected=\(onStageSelected != nil)")
            guard hasData else { return }
            let newStage: PipelinePointCloudCapture.Stage? = isSelected ? nil : stage
            selectedStage = newStage
            onStageSelected?(newStage)
            print("[DiagView] Called onStageSelected with \(newStage?.displayName ?? "nil")")
        } label: {
            HStack(spacing: 8) {
                Text(stage.displayName)
                    .font(PMTheme.mono(10, weight: .bold))
                    .foregroundColor(isSelected ? .black : PMTheme.textPrimary)
                    .frame(width: 90, alignment: .leading)

                Spacer()

                if hasData {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(formatCount(kept))
                            .font(PMTheme.mono(10))
                            .foregroundColor(isSelected ? .black.opacity(0.7) : PMTheme.green)
                    }

                    if removed > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Text(formatCount(removed))
                                .font(PMTheme.mono(10))
                                .foregroundColor(isSelected ? .black.opacity(0.7) : PMTheme.red)
                        }
                    }
                } else {
                    Text("--")
                        .font(PMTheme.mono(10))
                        .foregroundColor(PMTheme.textDimmed)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(isSelected ? PMTheme.green : PMTheme.surfaceCard)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .opacity(hasData ? 1.0 : 0.4)
    }

    // MARK: - Expanded Detail

    @ViewBuilder
    private func expandedDetail(for stageName: String) -> some View {
        switch stageName {
        case "INPUT":
            if let s = diagnostics.input {
                detailGrid([
                    ("Selection", s.selectionMode),
                    ("Tap Point", s.tapPoint.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "N/A"),
                    ("Norm Tap", s.normalizedTap.map { String(format: "(%.3f, %.3f)", $0.x, $0.y) } ?? "N/A"),
                    ("ROI", s.roi.map { String(format: "(%.0f,%.0f %.0fx%.0f)", $0.origin.x, $0.origin.y, $0.width, $0.height) } ?? "N/A"),
                    ("View Size", "\(Int(s.viewSize.width))x\(Int(s.viewSize.height))"),
                    ("Image Size", "\(Int(s.imageSize.width))x\(Int(s.imageSize.height))"),
                    ("Tracking", s.trackingState),
                    ("Mode", s.mode),
                ])
            }
        case "SEGMENTATION":
            if let s = diagnostics.segmentation {
                detailGrid([
                    ("Instances", "\(s.instanceCount)"),
                    ("Selected", s.selectedInstance),
                    ("Mask Size", "\(Int(s.maskSize.width))x\(Int(s.maskSize.height))"),
                    ("Pixel Count", formatCount(s.maskPixelCount)),
                    ("Duration", String(format: "%.1fms", s.durationMs)),
                ])
            }
        case "CONNECTED COMP":
            if let s = diagnostics.connectedComponent {
                detailGrid([
                    ("Enabled", s.enabled ? "Yes" : "No"),
                    ("Pixels Before", formatCount(s.pixelsBefore)),
                    ("Pixels After", formatCount(s.pixelsAfter)),
                    ("Retention", String(format: "%.1f%%", s.retentionPercent)),
                ])
            }
        case "DEPTH CONNECT":
            if let s = diagnostics.depthConnectivity {
                detailGrid([
                    ("Enabled", s.enabled ? "Yes" : "No"),
                    ("Pixels Before", formatCount(s.pixelsBefore)),
                    ("Pixels After", formatCount(s.pixelsAfter)),
                    ("Retention", String(format: "%.1f%%", s.retentionPercent)),
                ])
            }
        case "DEPTH FILTER":
            if let s = diagnostics.depthFilter {
                detailGrid([
                    ("Tap Depth", String(format: "%.3fm", s.tapDepth)),
                    ("Tolerance", String(format: "%.3fm", s.tolerance)),
                    ("Tol Percent", String(format: "%.0f%%", s.tolerancePercent * 100)),
                    ("Pixels Before", formatCount(s.pixelsBefore)),
                    ("Pixels After", formatCount(s.pixelsAfter)),
                    ("Retention", String(format: "%.1f%%", s.retentionPercent)),
                ])
            }
        case "POINT CLOUD":
            if let s = diagnostics.pointCloud {
                detailGrid([
                    ("Input Pixels", formatCount(s.inputPixels)),
                    ("Extracted", formatCount(s.extracted)),
                    ("After Outlier", formatCount(s.afterOutlierRemoval)),
                    ("After Downsample", formatCount(s.afterDownsample)),
                    ("After Unproject", formatCount(s.afterUnproject)),
                    ("After 3D Filter", formatCount(s.after3DFilter)),
                    ("Final Count", formatCount(s.finalCount)),
                    ("Depth Coverage", String(format: "%.0f%%", s.depthCoverage * 100)),
                    ("Depth Confidence", String(format: "%.2f", s.depthConfidence)),
                ])
            }
        case "CLUSTERING":
            if let s = diagnostics.clustering {
                detailGrid([
                    ("Nearest to Hit", String(format: "%.3fm", s.nearestDistToHit)),
                    ("Proximity Radius", String(format: "%.2fm", s.proximityRadius)),
                    ("After Proximity", formatCount(s.pointsAfterProximity)),
                    ("After Clustering", formatCount(s.pointsAfterClustering)),
                    ("Method", s.method),
                ])
            }
        case "BBOX ESTIMATION":
            if let s = diagnostics.bboxEstimation {
                detailGrid([
                    ("Method", s.method),
                    ("Hull Points", "\(s.hullPointCount)"),
                    ("Coarse Angle", String(format: "%.1f\u{00B0}", s.coarseAngleDeg)),
                    ("Fine Angle", String(format: "%.1f\u{00B0}", s.fineAngleDeg)),
                    ("Angle Delta", String(format: "%.1f\u{00B0}", s.angleDelta)),
                    ("Refinement Iters", "\(s.refinementIterations)"),
                ])
            }
        case "PLANE SNAP":
            if let s = diagnostics.planeSnap {
                detailGrid([
                    ("Snapped", s.snapped ? "Yes" : "No"),
                    ("Plane Count", "\(s.planeCount)"),
                    ("Pre-Snap Angle", String(format: "%.1f\u{00B0}", s.preSnapAngleDeg)),
                    ("Post-Snap Angle", String(format: "%.1f\u{00B0}", s.postSnapAngleDeg)),
                    ("Snap Delta", String(format: "%.1f\u{00B0}", s.snapDelta)),
                    ("Score", String(format: "%.2f", s.score)),
                    ("Method", s.method),
                ])
            }
        case "AXIS MAPPING":
            if let s = diagnostics.axisMapping {
                detailGrid([
                    ("Height Axis", "\(s.heightAxisIndex)"),
                    ("Length Axis", "\(s.lengthAxisIndex)"),
                    ("Width Axis", "\(s.widthAxisIndex)"),
                    ("Height", String(format: "%.1f cm", s.heightCm)),
                    ("Length", String(format: "%.1f cm", s.lengthCm)),
                    ("Width", String(format: "%.1f cm", s.widthCm)),
                ])
            }
        case "FLOOR":
            if let s = diagnostics.floor {
                detailGrid([
                    ("Detected", s.detected ? "Yes" : "No"),
                    ("Floor Y", s.floorY.map { String(format: "%.3f", $0) } ?? "N/A"),
                    ("Box Bottom Y", s.boxBottomY.map { String(format: "%.3f", $0) } ?? "N/A"),
                    ("Extension", s.extensionAmount.map { String(format: "%.1f cm", $0 * 100) } ?? "N/A"),
                    ("Method", s.method),
                ])
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Helpers

    private func detailGrid(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.0) { label, value in
                HStack {
                    Text(label)
                        .font(PMTheme.mono(10))
                        .foregroundColor(PMTheme.textDimmed)
                        .frame(width: 120, alignment: .leading)
                    Text(value)
                        .font(PMTheme.mono(10, weight: .medium))
                        .foregroundColor(PMTheme.textPrimary)
                    Spacer()
                }
            }
        }
    }

    private func statusColor(_ status: PipelineDiagnostics.StageStatus) -> Color {
        switch status {
        case .success: return PMTheme.green
        case .warning: return PMTheme.amber
        case .failed:  return PMTheme.red
        case .skipped: return PMTheme.textDimmed
        }
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 10_000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}
#endif
