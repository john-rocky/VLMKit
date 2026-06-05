//
//  BoxEditingView.swift
//  SnapMeasure
//

import SwiftUI
import RealityKit
import ARKit

/// View for editing a bounding box with gesture controls
struct BoxEditingView: View {
    @Binding var boundingBox: BoundingBox3D
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var editMode: EditMode = .none

    enum EditMode {
        case none
        case translate
        case scaleX
        case scaleY
        case scaleZ
        case rotate
    }

    var body: some View {
        VStack {
            // Edit mode selector
            HStack(spacing: 12) {
                editModeButton(mode: .translate, icon: "arrow.up.and.down.and.arrow.left.and.right", label: "Move")
                editModeButton(mode: .scaleX, icon: "arrow.left.and.right", label: "Width")
                editModeButton(mode: .scaleY, icon: "arrow.up.and.down", label: "Height")
                editModeButton(mode: .scaleZ, icon: "arrow.forward", label: "Depth")
                editModeButton(mode: .rotate, icon: "arrow.triangle.2.circlepath", label: "Rotate")
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer()

            // Dimension display
            dimensionDisplay

            // Action buttons
            HStack(spacing: 20) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button("Done") {
                    onDone()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .padding()
        .gesture(dragGesture)
        .gesture(rotationGesture)
    }

    // MARK: - Subviews

    private func editModeButton(mode: EditMode, icon: String, label: String) -> some View {
        Button {
            editMode = editMode == mode ? .none : mode
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .foregroundColor(editMode == mode ? .white : .primary)
            .padding(8)
            .background(editMode == mode ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var dimensionDisplay: some View {
        HStack(spacing: 24) {
            dimensionItem(label: "L", value: boundingBox.length, color: .red)
            dimensionItem(label: "W", value: boundingBox.width, color: .green)
            dimensionItem(label: "H", value: boundingBox.height, color: .blue)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func dimensionItem(label: String, value: Float, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(color)
            Text(String(format: "%.1f cm", value * 100))
                .font(.headline)
        }
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                handleDrag(translation: value.translation)
            }
    }

    private var rotationGesture: some Gesture {
        RotationGesture()
            .onChanged { angle in
                if editMode == .rotate {
                    boundingBox.rotateAroundY(by: Float(angle.radians) * 0.01)
                }
            }
    }

    private func handleDrag(translation: CGSize) {
        let sensitivity: Float = 0.0001

        switch editMode {
        case .translate:
            let dx = Float(translation.width) * sensitivity
            let dy = Float(-translation.height) * sensitivity
            boundingBox.translate(by: SIMD3<Float>(dx, dy, 0))

        case .scaleX:
            let scale = 1.0 + Float(translation.width) * sensitivity
            boundingBox.scale(alongAxis: 0, by: max(0.5, min(2.0, scale)))

        case .scaleY:
            let scale = 1.0 + Float(-translation.height) * sensitivity
            boundingBox.scale(alongAxis: 1, by: max(0.5, min(2.0, scale)))

        case .scaleZ:
            let scale = 1.0 + Float(translation.width) * sensitivity
            boundingBox.scale(alongAxis: 2, by: max(0.5, min(2.0, scale)))

        case .rotate:
            let angle = Float(translation.width) * sensitivity * 0.1
            boundingBox.rotateAroundY(by: angle)

        case .none:
            break
        }
    }
}

// MARK: - Box Editing Coordinator

class BoxEditingCoordinator: ObservableObject {
    @Published var isEditing = false
    @Published var boundingBox: BoundingBox3D?
    @Published var originalBox: BoundingBox3D?

    func startEditing(box: BoundingBox3D) {
        originalBox = box
        boundingBox = box
        isEditing = true
    }

    func commitChanges() -> BoundingBox3D? {
        isEditing = false
        return boundingBox
    }

    func cancelChanges() -> BoundingBox3D? {
        isEditing = false
        return originalBox
    }

    func updateBox(_ box: BoundingBox3D) {
        boundingBox = box
    }
}

#Preview {
    BoxEditingView(
        boundingBox: .constant(BoundingBox3D(
            center: .zero,
            extents: SIMD3<Float>(0.1, 0.05, 0.15),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        )),
        onDone: {},
        onCancel: {}
    )
}
