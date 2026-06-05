//
//  ARMeasurementView.swift
//  SnapMeasure
//

import SwiftUI
import RealityKit
import ARKit
import UIKit

struct ARMeasurementView: View {
    @StateObject private var viewModel = ARMeasurementViewModel()
    @AppStorage("measurementMode") private var measurementMode: MeasurementMode = .boxPriority
    @AppStorage("measurementUnit") private var measurementUnit: MeasurementUnit = .centimeters
    @AppStorage("selectionMode2") private var selectionMode: SelectionMode = .tap
    @AppStorage("showScanningTips") private var showScanningTips = true
    #if DEBUG
    @AppStorage("showMaskPreview") private var showMaskPreview = false
    @AppStorage("showDiagnostics") private var showDiagnostics = false
    #endif
    @State private var showScanningTipsSheet = false
    @State private var isLabelMode = false

    /// Active selection mode: label mode overrides user's selection
    private var activeSelectionMode: SelectionMode {
        isLabelMode ? .tap : selectionMode
    }

    var body: some View {
        ZStack {
            // AR Camera View
            if LiDARChecker.isARKitSupported {
                ARMeasurementViewRepresentable(
                    viewModel: viewModel,
                    measurementMode: measurementMode,
                    selectionMode: activeSelectionMode,
                    isLabelMode: isLabelMode
                )
                    .ignoresSafeArea()

                // Corner brackets overlay
                if !isLabelMode && activeSelectionMode == .tap {
                    GeometryReader { geometry in
                        CornerBracketsView(
                            phase: viewModel.animationPhase,
                            screenSize: geometry.size,
                            stabilityLevel: viewModel.stabilityLevel,
                            targetState: viewModel.reticleTargetState,
                            centerDepth: viewModel.reticleCenterDepth
                        )
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    // Tap position indicator
                    if let tapPos = viewModel.tapIndicatorPosition {
                        TapIndicatorView(position: tapPos)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                } else if isLabelMode {
                    GeometryReader { geometry in
                        LabelScanBracketsView(
                            phase: viewModel.animationPhase,
                            screenSize: geometry.size
                        )
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }

                // ML depth mode warning
                if viewModel.sessionManager.depthMode == .mlFallback {
                    VStack {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                            Text(String(localized: "ML Depth — accuracy may be lower than LiDAR"))
                                .font(PMTheme.mono(11))
                        }
                        .foregroundColor(PMTheme.amber)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(PMTheme.surfaceDark.opacity(0.85))
                        .clipShape(Capsule())
                        .padding(.top, 50)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                // Overlay UI (on top)
                GeometryReader { geometry in
                    VStack {
                        // Top bar
                        HStack {
                            if showScanningTips && !viewModel.isWorkflowActive {
                                Button(action: { showScanningTipsSheet = true }) {
                                    Image(systemName: "questionmark.circle")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(PMTheme.cyan)
                                        .frame(width: 36, height: 36)
                                        .background(PMTheme.surfaceDark.opacity(0.85))
                                        .clipShape(Circle())
                                        .overlay(Circle().strokeBorder(PMTheme.cyan.opacity(0.20), lineWidth: 0.5))
                                }
                                .accessibilityLabel("Scanning Tips")
                            }

                            #if DEBUG
                            Button(action: { viewModel.togglePointCloudViz() }) {
                                Image(systemName: viewModel.showPointCloudViz ? "circle.hexagongrid.fill" : "circle.hexagongrid")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(viewModel.showPointCloudViz ? PMTheme.green : PMTheme.cyan)
                                    .frame(width: 36, height: 36)
                                    .background(PMTheme.surfaceDark.opacity(0.85))
                                    .clipShape(Circle())
                                    .overlay(Circle().strokeBorder(
                                        (viewModel.showPointCloudViz ? PMTheme.green : PMTheme.cyan).opacity(0.20),
                                        lineWidth: 0.5
                                    ))
                            }
                            #endif

                            Spacer()

                            // Label scan button
                            if !viewModel.isWorkflowActive && !viewModel.isProcessing && !isLabelMode {
                                Button(action: { isLabelMode = true }) {
                                    Image(systemName: "doc.text.viewfinder")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(PMTheme.labelBlue)
                                        .frame(width: 36, height: 36)
                                        .background(PMTheme.surfaceDark.opacity(0.85))
                                        .clipShape(Circle())
                                        .overlay(Circle().strokeBorder(PMTheme.labelBlue.opacity(0.20), lineWidth: 0.5))
                                }
                                .accessibilityLabel("Scan Label")
                            } else if isLabelMode {
                                Button(action: { isLabelMode = false }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(PMTheme.textSecondary)
                                        .frame(width: 36, height: 36)
                                        .background(PMTheme.surfaceDark.opacity(0.85))
                                        .clipShape(Circle())
                                        .overlay(Circle().strokeBorder(PMTheme.textSecondary.opacity(0.20), lineWidth: 0.5))
                                }
                                .accessibilityLabel("Cancel Label Scan")
                            }

                            // Clear all button
                            if viewModel.completedBoxCount > 0 && !viewModel.isWorkflowActive {
                                Button(action: {
                                    viewModel.clearAllMeasurements()
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "trash")
                                        Text("\(viewModel.completedBoxCount)")
                                            .font(PMTheme.mono(11))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(PMTheme.red.opacity(0.8))
                                    .clipShape(Capsule())
                                }
                                .accessibilityLabel("Clear All Measurements")
                            }
                        }

                        Spacer()

                        // Action buttons when result is showing
                        if viewModel.workflowStep == .showingResult, let result = viewModel.currentMeasurement {
                            HStack(spacing: 10) {
                                // Discard button
                                Button(action: {
                                    viewModel.handleActionTap(.discard, mode: measurementMode)
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(PMTheme.red)
                                        .frame(width: 44, height: 44)
                                        .background(PMTheme.surfaceDark.opacity(0.85))
                                        .clipShape(Circle())
                                        .overlay(Circle().strokeBorder(PMTheme.red.opacity(0.20), lineWidth: 0.5))
                                }
                                .accessibilityLabel("Discard Measurement")

                                // Edit button
                                Button(action: {
                                    viewModel.handleActionTap(.edit, mode: measurementMode)
                                }) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(PMTheme.amber)
                                        .frame(width: 44, height: 44)
                                        .background(PMTheme.surfaceDark.opacity(0.85))
                                        .clipShape(Circle())
                                        .overlay(Circle().strokeBorder(PMTheme.amber.opacity(0.20), lineWidth: 0.5))
                                }
                                .accessibilityLabel("Edit Measurement")

                                // Copy dimensions button
                                Button(action: {
                                    let dims = measurementUnit.formatDimension(meters: result.length)
                                        + " × " + measurementUnit.formatDimension(meters: result.width)
                                        + " × " + measurementUnit.formatDimension(meters: result.height)
                                    UIPasteboard.general.string = dims
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 14))
                                        .foregroundColor(PMTheme.cyan)
                                        .frame(width: 44, height: 44)
                                        .background(PMTheme.surfaceDark.opacity(0.85))
                                        .clipShape(Circle())
                                        .overlay(Circle().strokeBorder(PMTheme.cyan.opacity(0.20), lineWidth: 0.5))
                                }
                                .accessibilityLabel("Copy Dimensions")

                                // NEW button
                                Button(action: {
                                    viewModel.saveAndReset(mode: measurementMode, unit: measurementUnit)
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 14))
                                        Text("NEW")
                                            .font(PMTheme.mono(14, weight: .bold))
                                    }
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 12)
                                    .background(PMTheme.green)
                                    .clipShape(Capsule())
                                    .shadow(color: PMTheme.green.opacity(0.4), radius: 8, x: 0, y: 2)
                                }
                                .accessibilityLabel("Save and New Measurement")
                            }
                        }

                        // Error message
                        if let error = viewModel.measurementError {
                            Text(error)
                                .font(PMTheme.mono(13))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(PMTheme.red.opacity(0.85))
                                .clipShape(Capsule())
                                .transition(.opacity)
                        }

                        // Instruction / status prompt (bottom)
                        if isLabelMode {
                            InstructionCard(mode: .label)
                        } else if viewModel.isProcessing {
                            InstructionCard(mode: .processing)
                        } else if viewModel.isRefining {
                            InstructionCard(mode: .refine)
                        } else if viewModel.currentMeasurement == nil && !viewModel.isReadingLabel {
                            if viewModel.hasPendingFirstTap {
                                VStack(spacing: 6) {
                                    if let failMsg = viewModel.secondTapFailureMessage {
                                        InstructionCard(mode: .refinementFailed(failMsg))
                                    } else {
                                        InstructionCard(mode: .secondTap)
                                    }
                                    Button(action: { viewModel.skipSecondTap() }) {
                                        Text("SKIP")
                                            .font(PMTheme.mono(11, weight: .bold))
                                            .foregroundColor(PMTheme.textSecondary)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 6)
                                            .background(PMTheme.surfaceDark.opacity(0.7))
                                            .clipShape(Capsule())
                                            .overlay(Capsule().strokeBorder(PMTheme.textSecondary.opacity(0.3), lineWidth: 0.5))
                                    }
                                }
                            } else if activeSelectionMode == .tap && viewModel.hasAutoPreview {
                                // First capture: encourage scanning around to refine
                                // 2+ captures: prompt to tap confirm
                                if viewModel.autoPreviewCaptureCount >= 2 {
                                    InstructionCard(mode: .confirm)
                                } else {
                                    InstructionCard(mode: .scanAround)
                                }
                            } else if activeSelectionMode == .tap && viewModel.reticleTargetState != .noTarget {
                                InstructionCard(mode: .holdSteady)
                            } else if activeSelectionMode == .tap && viewModel.animationPhase == .showingTargetBrackets {
                                InstructionCard(mode: .tap)
                            } else if activeSelectionMode == .box {
                                InstructionCard(mode: .box)
                            } else {
                                InstructionCard(mode: .ready(viewModel.trackingMessage), isTrackingReady: viewModel.isTrackingReady, isTrackingError: viewModel.isTrackingError)
                            }
                        }

                        // Selection mode toggle (Tap/Box)
                        if !viewModel.isWorkflowActive && !viewModel.isProcessing && !isLabelMode && !viewModel.isReadingLabel {
                            SelectionModeToggle(selectionMode: $selectionMode)
                        }
                    }
                    .padding()
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel.currentMeasurement != nil)
                .animation(.easeInOut(duration: 0.3), value: viewModel.workflowStep)
                #if DEBUG
                .sheet(isPresented: $viewModel.showDebugMask) {
                    if let image = viewModel.debugMaskImage {
                        DebugMaskCompareView(
                            image1: image,
                            image2: viewModel.debugMaskImage2
                        )
                    }
                }
                .sheet(isPresented: $viewModel.showDebugDepth) {
                    if let image = viewModel.debugDepthImage {
                        DebugImageView(image: image, title: "Depth Map (Bright=Close) + Masked Pixels (Green)")
                    }
                }
                #endif
                .sheet(isPresented: $showScanningTipsSheet) {
                    ScanningTipsView()
                }

                // Barcode scan effect overlay
                if viewModel.showBarcodeScanEffect, let labelData = viewModel.currentLabelData {
                    BarcodeScanEffectView(
                        labelData: labelData,
                        labelImageSize: viewModel.correctedLabelImageSize,
                        labelImage: viewModel.correctedLabelImage,
                        onComplete: { viewModel.barcodeScanEffectCompleted() }
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Floating reset button during scan animations
                if viewModel.isReadingLabel || viewModel.showBarcodeScanEffect {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                viewModel.resetLabelScan()
                                isLabelMode = false
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                            }
                            .padding(.trailing, 20)
                            .padding(.top, 60)
                        }
                        Spacer()
                    }
                    .transition(.opacity)
                }

                // Label result overlay
                if viewModel.showLabelResult, !viewModel.showLabelBillboard, let labelData = viewModel.currentLabelData {
                    ZStack {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)

                        LabelResultView(
                            labelData: labelData,
                            lineRevealed: viewModel.labelLineRevealed,
                            isComplete: viewModel.labelReadingComplete,
                            onDismiss: {
                                viewModel.dismissLabelResult()
                                isLabelMode = false
                            },
                            onRescan: {
                                viewModel.resetLabelScan()
                            }
                        )
                    }
                    .transition(.opacity)
                }

                // Dimension callout overlay
                if viewModel.showDimensionCallout {
                    GeometryReader { geometry in
                        DimensionCalloutView(
                            boxId: viewModel.calloutBoxId,
                            width: viewModel.calloutWidth,
                            height: viewModel.calloutHeight,
                            length: viewModel.calloutLength,
                            lineRevealed: viewModel.calloutLineRevealed,
                            transitionProgress: viewModel.calloutTransitionProgress,
                            targetPosition: viewModel.calloutTargetScreenPosition,
                            screenSize: geometry.size,
                            description: viewModel.objectDescription,
                            isDescribing: viewModel.isDescribingObject
                        )
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }

                // Status vignette flash (OK=green, NG=red)
                if viewModel.showStatusVignette {
                    StatusVignetteView(
                        isNG: viewModel.statusVignetteIsNG,
                        isVisible: $viewModel.showStatusVignette
                    )
                    .transition(.opacity)
                }
            } else {
                LiDARNotAvailableView()
            }
        }
        .onAppear {
            viewModel.startSession()
            viewModel.currentUnit = measurementUnit
            viewModel.currentMeasurementMode = measurementMode
            #if DEBUG
            viewModel.showMaskPreviewSetting = showMaskPreview
            viewModel.showDiagnosticsSetting = showDiagnostics
            #endif
        }
        .onDisappear {
            viewModel.pauseSession()
        }
        .onChange(of: measurementUnit) { _, newUnit in
            viewModel.currentUnit = newUnit
        }
        .onChange(of: measurementMode) { _, newMode in
            viewModel.currentMeasurementMode = newMode
        }
        #if DEBUG
        .onChange(of: showMaskPreview) { _, newValue in
            viewModel.showMaskPreviewSetting = newValue
        }
        .onChange(of: showDiagnostics) { _, newValue in
            viewModel.showDiagnosticsSetting = newValue
        }
        #endif
    }

}

// MARK: - AR View Representable with Tap and Pan Handling

struct ARMeasurementViewRepresentable: UIViewRepresentable {
    @ObservedObject var viewModel: ARMeasurementViewModel
    let measurementMode: MeasurementMode
    let selectionMode: SelectionMode
    let isLabelMode: Bool

    func makeUIView(context: Context) -> ARView {
        let arView = viewModel.sessionManager.arView!

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
        context.coordinator.tapGesture = tapGesture

        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        arView.addGestureRecognizer(panGesture)
        context.coordinator.panGesture = panGesture

        context.coordinator.arView = arView

        let boxSelectionRectView = BoxSelectionRectView(frame: arView.bounds)
        boxSelectionRectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(boxSelectionRectView)
        context.coordinator.boxSelectionRectView = boxSelectionRectView

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.measurementMode = measurementMode
        context.coordinator.selectionMode = selectionMode
        context.coordinator.isLabelMode = isLabelMode

        context.coordinator.tapGesture?.isEnabled = true
        context.coordinator.panGesture?.isEnabled = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, measurementMode: measurementMode, selectionMode: selectionMode, isLabelMode: isLabelMode)
    }

    class Coordinator: NSObject {
        let viewModel: ARMeasurementViewModel
        var measurementMode: MeasurementMode
        var selectionMode: SelectionMode
        var isLabelMode: Bool
        weak var arView: ARView?

        weak var tapGesture: UITapGestureRecognizer?
        weak var panGesture: UIPanGestureRecognizer?

        var boxSelectionRectView: BoxSelectionRectView?

        private var activeDragType: DragType?
        private var lastPanLocation: CGPoint?

        enum DragType {
            case faceHandle(HandleType)
            case rotationRing
            case boxSelection(startPoint: CGPoint)
        }

        init(viewModel: ARMeasurementViewModel, measurementMode: MeasurementMode, selectionMode: SelectionMode, isLabelMode: Bool) {
            self.viewModel = viewModel
            self.measurementMode = measurementMode
            self.selectionMode = selectionMode
            self.isLabelMode = isLabelMode
        }

        @MainActor @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            guard let arView = arView else { return }

            let location = gesture.location(in: arView)
#if DEBUG
            print("[Tap] Location: \(location)")
#endif

            // Hit test for 3D entities first
            let results = arView.hitTest(location, query: .nearest, mask: .all)

            for result in results {
                var entity: Entity? = result.entity
                while let current = entity {
                    if ActionIconBuilder.isActionEntity(current.name),
                       let actionType = ActionIconBuilder.parseActionType(entityName: current.name) {
#if DEBUG
                        print("[Tap] Action icon tapped: \(actionType)")
#endif
                        viewModel.handleActionTap(actionType, mode: measurementMode)
                        return
                    }

                    if current.name == "completed_billboard_bg" {
                        if let boxId = viewModel.findCompletedBoxId(for: current) {
#if DEBUG
                            print("[Tap] Completed billboard tapped, boxId: \(boxId)")
#endif
                            viewModel.showCompletedBoxActions(boxId: boxId)
                            return
                        }
                    }

                    entity = current.parent
                }
            }

            if viewModel.selectedCompletedBoxId != nil {
                viewModel.dismissCompletedBoxActions()
                return
            }

            if viewModel.isEditing { return }

            if viewModel.isRefining {
                Task { await viewModel.handleRefinementTap(at: location, mode: measurementMode) }
                return
            }

            // Label mode: route to label handler
            if isLabelMode {
                Task { await viewModel.handleLabelTap(at: location) }
                return
            }

            // Only handle measurement taps in tap mode
            guard selectionMode == .tap else { return }

            Task {
                await viewModel.handleTap(at: location, mode: measurementMode)
            }
        }

        @MainActor @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let arView = arView else { return }

            let location = gesture.location(in: arView)

            switch gesture.state {
            case .began:
                if viewModel.isEditing {
                    if let dragType = hitTest(at: location, in: arView) {
                        activeDragType = dragType
                        lastPanLocation = location
#if DEBUG
                        print("[Pan] Started editing drag: \(dragType)")
#endif
                    }
                } else if selectionMode == .box && !viewModel.isProcessing {
                    activeDragType = .boxSelection(startPoint: location)
                    boxSelectionRectView?.clearSelection()
#if DEBUG
                    print("[Pan] Started box selection at: \(location)")
#endif
                }

            case .changed:
                guard let dragType = activeDragType else { return }

                switch dragType {
                case .faceHandle(let handleType):
                    guard let lastLocation = lastPanLocation else { return }
                    let delta = CGPoint(
                        x: location.x - lastLocation.x,
                        y: location.y - lastLocation.y
                    )
                    viewModel.handleFaceDrag(handleType: handleType, screenDelta: delta, mode: measurementMode)
                    lastPanLocation = location

                case .rotationRing:
                    guard let lastLocation = lastPanLocation else { return }
                    let delta = CGPoint(
                        x: location.x - lastLocation.x,
                        y: location.y - lastLocation.y
                    )
                    viewModel.handleRotationDrag(screenDelta: delta, touchLocation: location)
                    lastPanLocation = location

                case .boxSelection(let startPoint):
                    let rect = CGRect(
                        x: min(startPoint.x, location.x),
                        y: min(startPoint.y, location.y),
                        width: abs(location.x - startPoint.x),
                        height: abs(location.y - startPoint.y)
                    )
                    let isValid = rect.width >= BoxSelectionRectView.minimumSize
                        && rect.height >= BoxSelectionRectView.minimumSize
                    boxSelectionRectView?.isRectValid = isValid
                    boxSelectionRectView?.selectionRect = rect
                }

            case .ended, .cancelled:
                guard let dragType = activeDragType else { return }

                switch dragType {
                case .faceHandle, .rotationRing:
#if DEBUG
                    print("[Pan] Ended editing drag")
#endif
                    viewModel.finishDrag()

                case .boxSelection(let startPoint):
                    let rect = CGRect(
                        x: min(startPoint.x, location.x),
                        y: min(startPoint.y, location.y),
                        width: abs(location.x - startPoint.x),
                        height: abs(location.y - startPoint.y)
                    )
                    boxSelectionRectView?.clearSelection()

                    if gesture.state == .ended
                        && rect.width >= BoxSelectionRectView.minimumSize
                        && rect.height >= BoxSelectionRectView.minimumSize {
#if DEBUG
                        print("[Pan] Box selection completed: \(rect)")
#endif
                        Task {
                            await viewModel.handleBoxSelection(
                                rect: rect,
                                viewSize: arView.bounds.size,
                                mode: measurementMode
                            )
                        }
                    }
                }

                activeDragType = nil
                lastPanLocation = nil

            default:
                break
            }
        }

        private func hitTest(at location: CGPoint, in arView: ARView) -> DragType? {
            let results = arView.hitTest(location, query: .nearest, mask: .all)

            for result in results {
                var entity: Entity? = result.entity
                while let current = entity {
                    let hitType = BoxVisualization.parseHit(entityName: current.name)
                    switch hitType {
                    case .faceHandle(let handleType):
                        return .faceHandle(handleType)
                    case .rotationRing:
                        return .rotationRing
                    case .none:
                        break
                    }
                    entity = current.parent
                }
            }

            return nil
        }
    }
}

#Preview {
    ARMeasurementView()
}
