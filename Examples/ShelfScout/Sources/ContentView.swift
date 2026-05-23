import SwiftUI
import VLMKit

struct ContentView: View {
    @StateObject private var vm = ScanViewModel()
    @State private var detail = 3
    @State private var picker: PickerKind?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let image = vm.capturedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    phaseContent
                }
                .padding()
            }
            .navigationTitle("ShelfScout")
            .task { await vm.loadModelIfNeeded() }
            .sheet(item: $picker) { kind in
                ImagePicker(sourceType: kind.source) { image in
                    Task { await vm.scan(image, detail: detail) }
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch vm.phase {
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading \(vm.modelName)…")
            } currentValueLabel: {
                Text("\(Int(fraction * 100))%")
            }
        case .ready:
            captureControls
        case .scanning(let done, let total):
            ProgressView(value: Double(done), total: Double(total)) {
                Text("Scanning shelf…")
            } currentValueLabel: {
                Text("tile \(done)/\(total)")
            }
        case .result(let report):
            ResultView(report: report)
            captureControls
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
            captureControls
        }
    }

    @ViewBuilder private var captureControls: some View {
        // The grid size shows VLMKit's fan-out: more tiles = higher effective
        // resolution per VLM call, at the cost of more sequential calls.
        Stepper("Detail: \(detail)×\(detail) tiles", value: $detail, in: 2...4)
        HStack {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { picker = .camera } label: {
                    Label("Camera", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)
            }
            Button { picker = .library } label: {
                Label("Photos", systemImage: "photo")
            }
            .buttonStyle(.bordered)
        }
    }

    enum PickerKind: Identifiable {
        case camera, library
        var id: Int { hashValue }
        var source: UIImagePickerController.SourceType { self == .camera ? .camera : .photoLibrary }
    }
}

/// Renders a `ShelfReport`: a big total, then per-product counts.
private struct ResultView: View {
    let report: ShelfReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(report.totalCount)").font(.system(size: 44, weight: .bold))
                Text("items").foregroundStyle(.secondary)
            }
            ForEach(report.items, id: \.name) { item in
                HStack {
                    Text(item.name)
                    Spacer()
                    Text("×\(item.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
