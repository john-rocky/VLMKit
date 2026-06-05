import SwiftUI
import UIKit
import VisionKit

/// SwiftUI wrapper for `VNDocumentCameraViewController` — Apple's built-in document
/// scanner (live edge detection, auto-shutter when stable, perspective correction,
/// multi-page). Same shape as `ImagePicker`, but returns every scanned page so the
/// caller can decide whether to use only the first or all of them.
///
/// Used by the Document QA demo so the user gets a real scanner UX instead of a
/// generic camera roll: hold the phone over a receipt/form, it auto-shoots a clean,
/// flat crop ready for VLM extraction.
struct DocumentScannerView: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onScan(pages)
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            parent.dismiss()
        }
    }
}
