//
//  ARViewContainer.swift
//  SnapMeasure
//

import SwiftUI
import RealityKit
import ARKit

/// UIViewRepresentable wrapper for ARView
struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var sessionManager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        let arView = sessionManager.arView!
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Updates handled by sessionManager
    }
}

/// Coordinator for handling AR interactions
class ARViewCoordinator: NSObject {
    var parent: ARViewContainer

    init(_ parent: ARViewContainer) {
        self.parent = parent
    }
}
