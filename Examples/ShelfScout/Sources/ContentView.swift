import SwiftUI
import Translation
import VLMKit

/// Recipe-agnostic demo shell: a demo picker, the input photo on top, and the
/// structured result below. Selecting a result spotlights it on the photo (the
/// background dims, the chosen box stays bright, a callout types out the detail),
/// and an auto-tour walks each detection one by one.
///
/// Language: the VLM is always prompted in English. In Japanese mode the user's
/// question is translated to English before inference, and the model's answer is
/// translated back to Japanese before display, via Apple's Translation framework.
struct ContentView: View {
    @StateObject private var vm = DemoViewModel()
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.english.rawValue
    /// Describe & Point: render YOLOE instance-mask silhouettes on the photo instead of
    /// only the rect boxes. Persisted; only takes effect on that demo.
    @AppStorage("describePointShowMasks") private var showMasks = false
    @State private var detail = 3
    @State private var query = ""
    @State private var englishQuery = ""
    @State private var picker: PickerKind?
    /// Key currently highlighted (product name / person id) — links rows ↔ boxes.
    @State private var selectedKey: String?
    @State private var isTouring = false
    @State private var tourTask: Task<Void, Never>?

    // Translation plumbing (Translation framework vends sessions via .translationTask).
    @State private var inConfig: TranslationSession.Configuration?
    @State private var outConfig: TranslationSession.Configuration?
    @State private var jaCache: [String: String] = [:]   // English → Japanese (output)
    @State private var pendingRun: PendingRun?
    /// Listing: drives the Background Studio modal that lifts the subject and
    /// composites a chosen background onto it.
    @State private var showBackgroundStudio = false
    /// AR Measure: presents the ported ARMeasurementView full-screen over the
    /// shell. Selecting the AR Measure demo from the picker swaps the capture
    /// controls for a Start button that flips this on.
    @State private var showARMeasure = false
    /// Receipt: the bottom panel is too short to show every line item, so the
    /// extracted card opens in a detents sheet. Flipped on automatically when a
    /// receipt result lands (see `.onChange(of: vm.resultCount)`); the user
    /// can dismiss and re-open from the summary tile.
    @State private var showReceiptSheet = false

    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .english }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                imageArea
                    .frame(height: geo.size.height * 0.5)
                Divider()
                bottomPanel
                    .frame(maxHeight: .infinity)
            }
        }
        // Model preload is kicked off by DemoViewModel.init (= app launch); no
        // .task hook needed here. loadModelIfNeeded is idempotent if anything else
        // ever wants to re-trigger it.
        .sheet(item: $picker) { kind in
            switch kind {
            case .camera, .library:
                ImagePicker(sourceType: kind.imagePickerSource!) { image in
                    let demo = vm.selectedDemo
                    resetSelection()
                    if demo.usesDocumentScanner {
                        // Library photos of documents get the same perspective
                        // correction the scanner camera does at capture time.
                        Task {
                            let rectified = await DocumentRectifier.rectify(image)
                            await MainActor.run { requestRun(.newImage([rectified])) }
                        }
                    } else {
                        requestRun(.newImage([image]))
                    }
                }
                .ignoresSafeArea()
            case .scanner:
                // All scanned pages flow into Document QA's multi-page pipeline.
                DocumentScannerView { pages in
                    guard !pages.isEmpty else { return }
                    resetSelection()
                    requestRun(.newImage(pages))
                }
                .ignoresSafeArea()
            case .multiPhoto:
                // Listing: pick 1–5 angle photos of the same item.
                MultiPhotoPicker(selectionLimit: 5) { images in
                    guard !images.isEmpty else { return }
                    resetSelection()
                    requestRun(.newImage(images))
                }
                .ignoresSafeArea()
            }
        }
        // Translate the model's English answer to Japanese for display.
        .translationTask(outConfig) { session in await translateOutput(using: session) }
        // Translate the Japanese question to English (then run, if a run is pending).
        .translationTask(inConfig) { session in await translateInputThenRun(using: session) }
        .onChange(of: vm.resultCount) { triggerOutputTranslation() }
        .onChange(of: languageRaw) { triggerOutputTranslation() }
        .onChange(of: query) { englishQuery = "" }
        // Selecting a row/box from another page in a multi-page Document QA scan
        // auto-flips the page picker so the highlighted box is actually visible.
        .onChange(of: selectedKey) { _, newKey in flipToSelectedPage(newKey) }
        // Background Studio for the Listing demo. Uses the first captured page
        // as the basis (hero shot) and SharedVLM.runner for VLM calls.
        .sheet(isPresented: $showBackgroundStudio) { backgroundStudioSheet }
        // Receipt: full card (line items + export) in a detents sheet so each
        // row is actually readable. Auto-opens when a new receipt result lands.
        .sheet(isPresented: $showReceiptSheet) {
            if let data = vm.receiptData {
                NavigationStack {
                    ScrollView {
                        ReceiptCard(data: data).padding()
                    }
                    .navigationTitle("Receipt")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showReceiptSheet = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: vm.resultCount) {
            if vm.selectedDemo.id == Demo.receipt.id, vm.receiptData != nil {
                showReceiptSheet = true
            }
        }
        // AR Measure: the ported ARMeasurementView gets the whole screen. A
        // floating close button is the only chrome added on top.
        .fullScreenCover(isPresented: $showARMeasure) {
            ZStack(alignment: .topTrailing) {
                ARMeasurementView()
                    .ignoresSafeArea()
                Button {
                    showARMeasure = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .padding(.top, 6)
                        .padding(.trailing, 12)
                }
                .accessibilityLabel("Close AR Measure")
            }
        }
    }

    @ViewBuilder private var backgroundStudioSheet: some View {
        if let source = vm.capturedPages.first,
           let vlmImage = VLMImage(uiImage: source.normalizedUp()) {
            BackgroundStudioView(
                sourceImage: source.normalizedUp(),
                vlmImage: vlmImage,
                runner: SharedVLM.runner,
                onApply: { composed in vm.listingHeroImage = composed }
            )
        } else {
            // Defensive: sheet shouldn't open without a captured page, but if
            // it does, show a clear empty state instead of a blank modal.
            VStack(spacing: 8) {
                Image(systemName: "photo").font(.title)
                Text("No photo to work with.").font(.callout)
            }
            .padding()
        }
    }

    /// If the just-selected detection lives on a page other than the one being shown,
    /// move the page picker to it. No-op for single-page or for detections without a
    /// page tag (other demos).
    private func flipToSelectedPage(_ key: String?) {
        guard let key,
              case .result(let result) = vm.phase,
              let detection = result.detections.first(where: { $0.key == key }),
              let page = detection.page,
              page != vm.currentPageIndex,
              vm.capturedPages.indices.contains(page) else { return }
        vm.currentPageIndex = page
    }

    // MARK: - Input (top half) — photo, spotlight overlay, language + tour buttons.

    @ViewBuilder private var imageArea: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image = vm.displayedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                if case .result(let result) = vm.phase {
                    let shown = displayed(result)
                    // Optional YOLOE instance-mask silhouettes (Describe & Point). Drawn
                    // BELOW the spotlight so the selection's dim affects them the same
                    // way it does the photo — the spotlighted box shows its mask
                    // brightly, the others stay visible but muted.
                    if showMasks,
                       vm.selectedDemo.id == Demo.describeAndPoint.id,
                       let mask = vm.describeMaskImage {
                        Image(decorative: mask, scale: 1, orientation: .up)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .opacity(0.55)
                            .allowsHitTesting(false)
                    }
                    // For multi-page Document QA, only show detections from the page
                    // the user is currently viewing. Other demos leave Detection.page
                    // nil, so the filter is a no-op for them.
                    let pageDetections = shown.detections.filter {
                        $0.page == nil || $0.page == vm.currentPageIndex
                    }
                    if vm.selectedDemo.usesDocumentScanner {
                        // Cyber HUD: every detected field's box + label floats on the
                        // photo (no dim-others spotlight); tapping a row still
                        // highlights the matching one.
                        DocumentHUDOverlay(
                            imageSize: image.size,
                            detections: pageDetections,
                            selectedKey: selectedKey,
                            onTap: handleTap
                        )
                    } else {
                        SpotlightOverlay(
                            imageSize: image.size,
                            detections: pageDetections,
                            selectedKey: selectedKey,
                            onTap: handleTap,
                            onTapPoint: vm.selectedDemo.isTapToAnalyze
                                ? { point in Task { await vm.addROI(atNormalizedPoint: point) } }
                                : nil
                        )
                    }
                    if !pageDetections.isEmpty {
                        trailingPhotoControls
                    }
                    if vm.selectedDemo.isTapToAnalyze {
                        roiHint(hasRegions: !pageDetections.isEmpty)
                    }
                }
                if vm.isSegmenting || vm.roiDetailInFlight > 0 {
                    ProgressView()
                        .tint(.white)
                        .padding(14)
                        .background(.black.opacity(0.55), in: Circle())
                }
            } else {
                ContentUnavailableView(
                    "Pick a photo",
                    systemImage: "photo.badge.plus",
                    description: Text("Take or choose a photo, then run the selected demo on it.")
                )
            }
            languageMenu
        }
        .clipped()
    }

    private var languageMenu: some View {
        Menu {
            Picker("Language", selection: Binding(get: { language }, set: { languageRaw = $0.rawValue })) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Image(systemName: "globe")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Stack of overlay buttons in the top-right of the photo: auto-tour, plus the
    /// optional mask-silhouette toggle for Describe & Point.
    @ViewBuilder private var trailingPhotoControls: some View {
        VStack(spacing: 8) {
            Button { isTouring ? stopTour() : startTour() } label: {
                roundOverlayButton(systemImage: isTouring ? "stop.fill" : "play.fill", tint: .white)
            }
            if vm.selectedDemo.id == Demo.describeAndPoint.id {
                Button { showMasks.toggle() } label: {
                    roundOverlayButton(systemImage: "lasso", tint: showMasks ? .yellow : .white)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func roundOverlayButton(systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.headline)
            .foregroundStyle(tint)
            .frame(width: 42, height: 42)
            .background(.black.opacity(0.5), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.6), lineWidth: 1))
    }

    /// Guidance pinned to the bottom of the photo for the tap-to-analyze demo.
    @ViewBuilder private func roiHint(hasRegions: Bool) -> some View {
        if vm.roiUnavailable {
            hintLabel("MobileSAM models not found — see the example README.", icon: "exclamationmark.triangle")
        } else if !hasRegions {
            hintLabel("Tap an object to segment a region.", icon: "hand.tap")
        }
    }

    private func hintLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption).bold()
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 14)
            .allowsHitTesting(false)
    }

    /// Compact receipt summary used in the bottom panel — merchant, total, item
    /// count, and a chevron prompting the user to tap. Tapping opens the full
    /// `ReceiptCard` in a detents sheet (where the line items have room).
    @ViewBuilder private func receiptSummaryTile(data: ReceiptData) -> some View {
        Button {
            showReceiptSheet = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.merchant ?? "Receipt")
                        .font(.headline).lineLimit(1)
                        .foregroundStyle(.primary)
                    Text("\(data.items.count) item\(data.items.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let total = data.total {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatReceiptTotal(total, currency: data.currency))
                            .font(.title3).bold().monospacedDigit()
                            .foregroundStyle(.primary)
                        if let date = data.date {
                            Text(date).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Image(systemName: "chevron.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tint.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func formatReceiptTotal(_ total: Double, currency: String?) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        let amount = f.string(from: NSNumber(value: total)) ?? String(format: "%.2f", total)
        if let currency, !currency.isEmpty { return "\(currency) \(amount)" }
        return amount
    }

    // MARK: - Output (bottom half) — demo picker, result, pinned controls.

    @ViewBuilder private var bottomPanel: some View {
        VStack(spacing: 12) {
            demoPicker
            // Page picker is shown for multi-image demos (Document QA pages,
            // Listing angle photos). Other demos treat `currentPageIndex` as 0.
            let isMultiImageDemo = vm.selectedDemo.id == Demo.documentQA.id
                || vm.selectedDemo.id == Demo.listing.id
            if isMultiImageDemo && vm.capturedPages.count > 1 {
                pagePicker
            }
            stateContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if showsControls {
                captureControls
            }
        }
        .padding()
    }

    /// Segmented page selector for a multi-page Document QA scan. Binds to
    /// `vm.currentPageIndex` so flipping pages updates the photo, the spotlight
    /// filter, and (via the answer's cited page) auto-navigation.
    private var pagePicker: some View {
        Picker("Page", selection: $vm.currentPageIndex) {
            ForEach(vm.capturedPages.indices, id: \.self) { index in
                Text("\(index + 1)").tag(index)
            }
        }
        .pickerStyle(.segmented)
        .disabled(vm.isBusy)
    }

    /// Switching the demo reuses the loaded model; it just clears the old result.
    /// Horizontally scrollable pill row instead of a segmented picker — with the
    /// demo count past 5 the segmented control gets unreadably narrow. Selected
    /// pill auto-scrolls into view so a tour-of-demos feels coherent.
    private var demoPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(vm.demos) { demo in
                        demoPill(for: demo)
                            .id(demo.id)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .onAppear {
                proxy.scrollTo(vm.selectedDemo.id, anchor: .center)
            }
            .onChange(of: vm.selectedDemo.id) { _, id in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder private func demoPill(for demo: Demo) -> some View {
        let isSelected = demo.id == vm.selectedDemo.id
        Button {
            guard !isSelected else { return }
            resetSelection()
            vm.select(demo)
        } label: {
            Text(demo.name)
                .font(.subheadline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color.accentColor : Color(.secondarySystemBackground),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy)
    }

    @ViewBuilder private var stateContent: some View {
        switch vm.phase {
        case .preparing:
            statusRow("Loading \(vm.modelName)…")
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading \(vm.modelName)…")
            } currentValueLabel: {
                Text("\(Int(fraction * 100))%")
            }
        case .running(let done, let total):
            if total == 0 {
                statusRow("Analyzing…")
            } else {
                ProgressView(value: Double(done), total: Double(total)) {
                    Text("Analyzing…")
                } currentValueLabel: {
                    Text("\(done)/\(total)")
                }
            }
        case .ready:
            readyHint
        case .result(let result):
            if vm.selectedDemo.id == Demo.receipt.id, let data = vm.receiptData {
                // Receipt: compact summary tile in the bottom panel; the full
                // card (line items + export) opens in a sheet so it has room.
                receiptSummaryTile(data: data)
            } else if vm.selectedDemo.id == Demo.businessCard.id, let data = vm.businessCardData {
                // Business Card opens a CNContactViewController preview when the
                // user taps Save — bespoke card displays the extracted contact.
                BusinessCardCard(data: data)
            } else if vm.selectedDemo.id == Demo.idDocument.id, let data = vm.idDocumentData {
                // ID has a privacy-first bespoke card with a Vision face crop
                // and a Copy JSON button for downstream KYC workflows.
                IDDocumentCard(data: data, face: vm.idDocumentFace)
            } else if vm.selectedDemo.id == Demo.listing.id, let data = vm.listingData {
                // Listing has a draft + a refinement TextField that re-runs
                // the VLM with the previous draft + the user's instruction.
                ListingCard(
                    data: data,
                    isRefining: vm.isRefiningListing,
                    hasHeroImage: vm.listingHeroImage != nil,
                    onRefine: { instruction in
                        Task { await vm.refineListing(instruction: instruction) }
                    },
                    onGenerateBackground: { showBackgroundStudio = true },
                    onClearHero: { vm.listingHeroImage = nil }
                )
            } else {
                ResultView(
                    result: displayed(result),
                    summaryPending: vm.roiSummaryPending,
                    selectedKey: selectedKey,
                    onTapKey: handleTap,
                    highlightsCaptionMentions: vm.selectedDemo.id == Demo.describeAndPoint.id
                )
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.footnote)
        }
    }

    @ViewBuilder private var readyHint: some View {
        if vm.hasImage {
            Text("Tap Run to analyze this photo with \(vm.selectedDemo.name).")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Color.clear
        }
    }

    private var showsControls: Bool {
        switch vm.phase {
        case .ready, .result, .failed: true
        default: false
        }
    }

    private func statusRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var captureControls: some View {
        if vm.selectedDemo.isFullScreenAR {
            // AR Measure replaces the photo→result flow entirely; one big button
            // launches the ported ARMeasurementView in a full-screen cover.
            Button {
                showARMeasure = true
            } label: {
                Label("Start AR Measure", systemImage: "ruler.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
        // Per-detection question (e.g. a PPE check for the crowd demo). Empty = the
        // recipe's default prompt. Only demos that take a question show this field.
        // In Japanese mode the question is typed in Japanese; its English translation
        // (what the VLM actually receives) is previewed below.
        if let placeholder = vm.selectedDemo.queryPlaceholder {
            VStack(alignment: .leading, spacing: 4) {
                TextField(placeholder, text: $query, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .font(.callout)
                    .submitLabel(.done)
                    .onSubmit { submitQueryTranslation() }
                if language.needsTranslation, !englishQuery.isEmpty {
                    Text("EN: \(englishQuery)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        // The grid size shows VLMKit's fan-out: more tiles = higher effective
        // resolution per VLM call, at the cost of more sequential calls. Only grid
        // demos expose it; Vision-driven demos (α2) decide their own region count.
        if let range = vm.selectedDemo.gridDetail {
            Stepper("Detail: \(detail)×\(detail) tiles", value: $detail, in: range)
        }
        HStack {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                // Document QA, Receipt, Business Card, and ID all work off printed
                // pages, so they get Apple's document scanner (live edge detection,
                // auto-shutter, perspective correction) in place of the raw camera.
                // Other demos keep the standard camera roll picker.
                let usesScanner = vm.selectedDemo.usesDocumentScanner
                Button { picker = usesScanner ? .scanner : .camera } label: {
                    Label(
                        usesScanner ? "Scan" : "Camera",
                        systemImage: usesScanner ? "doc.viewfinder" : "camera"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            // Listing wants multiple angle photos of one item, so it gets the
            // PHPicker (multi-select) in place of the single-image library picker.
            let multiPhoto = vm.selectedDemo.id == Demo.listing.id
            Button { picker = multiPhoto ? .multiPhoto : .library } label: {
                Label(
                    multiPhoto ? "Photos (up to 5)" : "Photos",
                    systemImage: multiPhoto ? "photo.stack" : "photo"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        // ROI Zoom: analyze the image center without tapping (the Center option from §5).
        if vm.selectedDemo.isTapToAnalyze && vm.hasImage {
            Button {
                Task { await vm.addROIAtCenter() }
            } label: {
                Label("Analyze center", systemImage: "viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(vm.isSegmenting || vm.roiUnavailable)
        }
        // Tap-to-analyze demos (ROI Zoom) have no run-once pass — the tap is the action.
        if vm.hasImage && !vm.selectedDemo.isTapToAnalyze {
            Button {
                resetSelection()
                requestRun(.current)
            } label: {
                Label("Run \(vm.selectedDemo.name)", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        }   // end of `else` for isFullScreenAR
    }

    // MARK: - Run (with input translation when in Japanese).

    private enum PendingRun {
        /// Newly-captured pages (one element for camera/library, many for a multi-page
        /// scan). Caller is responsible for wrapping a single UIImage as `[image]`.
        case newImage([UIImage])
        case current
    }

    /// Start a run. In Japanese mode with a non-empty question, first translate the
    /// question to English (the translation task then performs the run).
    private func requestRun(_ pending: PendingRun) {
        if language.needsTranslation, !query.isEmpty {
            pendingRun = pending
            triggerInputTranslation()
        } else {
            performRun(pending, query: query)
        }
    }

    private func performRun(_ pending: PendingRun, query text: String) {
        switch pending {
        case .newImage(let pages):
            Task { await vm.analyze(pages, detail: detail, query: text) }
        case .current:
            Task { await vm.analyzeCurrent(detail: detail, query: text) }
        }
    }

    // MARK: - Selection & auto-tour.

    /// Manual selection (row or box tap, or background tap with `nil`). Always
    /// cancels the auto-tour so the user takes over.
    private func handleTap(_ key: String?) {
        stopTour()
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedKey = (key != nil && selectedKey == key) ? nil : key
        }
    }

    private func resetSelection() {
        stopTour()
        selectedKey = nil
    }

    /// Spotlight each detection in turn, dwelling on each long enough for its callout
    /// to finish typing. Pure presentation — replays the (translated) descriptions
    /// already computed, so it is smooth and re-runnable without re-inference.
    private func startTour() {
        stopTour()
        guard case .result(let english) = vm.phase else { return }
        let result = displayed(english)
        let keys = orderedTourKeys(result)
        guard !keys.isEmpty else { return }
        isTouring = true
        tourTask = Task { @MainActor in
            for key in keys {
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.35)) { selectedKey = key }
                try? await Task.sleep(for: .seconds(dwellTime(for: key, in: result)))
            }
            if !Task.isCancelled {
                withAnimation { selectedKey = nil }
            }
            isTouring = false
        }
    }

    private func stopTour() {
        tourTask?.cancel()
        tourTask = nil
        isTouring = false
    }

    /// Unique keys in the order their boxes first appear, so the tour walks the photo.
    private func orderedTourKeys(_ result: DemoResult) -> [String] {
        var seen = Set<String>()
        return result.detections.compactMap { seen.insert($0.key).inserted ? $0.key : nil }
    }

    /// Time to dwell on a key: long enough to type its callout, plus a read pause.
    private func dwellTime(for key: String, in result: DemoResult) -> Double {
        let length = result.detections.first { $0.key == key }?.detail?.count ?? 0
        return max(1.6, Typewriter.duration(forLength: length) + 1.2)
    }

    // MARK: - Translation.

    /// The result as shown: translated to Japanese when in Japanese mode (falling
    /// back to English text until the cache fills), otherwise the English result.
    private func displayed(_ english: DemoResult) -> DemoResult {
        language.needsTranslation ? localized(english, using: jaCache) : english
    }

    private func triggerInputTranslation() {
        if inConfig == nil {
            inConfig = .init(source: Locale.Language(identifier: "ja"), target: Locale.Language(identifier: "en"))
        } else {
            inConfig?.invalidate()
        }
    }

    /// Translate the question for the preview only (no run pending).
    private func submitQueryTranslation() {
        guard language.needsTranslation, !query.isEmpty else { return }
        pendingRun = nil
        triggerInputTranslation()
    }

    private func triggerOutputTranslation() {
        guard language.needsTranslation, case .result = vm.phase else { return }
        jaCache = [:]
        if outConfig == nil {
            outConfig = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "ja"))
        } else {
            outConfig?.invalidate()
        }
    }

    private func translateInputThenRun(using session: TranslationSession) async {
        let original = query
        var english = original
        do { english = try await session.translate(original).targetText } catch {}
        englishQuery = english
        if let pending = pendingRun {
            pendingRun = nil
            performRun(pending, query: english)
        }
    }

    private func translateOutput(using session: TranslationSession) async {
        guard case .result(let result) = vm.phase else { return }
        let strings = translatableStrings(in: result)
        guard !strings.isEmpty else { return }
        do {
            let responses = try await session.translations(from: strings.map { TranslationSession.Request(sourceText: $0) })
            var cache: [String: String] = [:]
            for response in responses { cache[response.sourceText] = response.targetText }
            jaCache = cache
        } catch {}
    }

    enum PickerKind: Identifiable {
        case camera, library, scanner, multiPhoto
        var id: Int { hashValue }
        /// Source for `UIImagePickerController`. `nil` for the document scanner
        /// (`VNDocumentCameraViewController`) and the multi-photo picker
        /// (`PHPickerViewController`), which have their own presenters.
        var imagePickerSource: UIImagePickerController.SourceType? {
            switch self {
            case .camera: .camera
            case .library: .photoLibrary
            case .scanner, .multiPhoto: nil
            }
        }
    }
}

// MARK: - Photo overlay: dim everything except the selected box(es) + a typed callout.

private struct SpotlightOverlay: View {
    let imageSize: CGSize
    let detections: [Detection]
    let selectedKey: String?
    let onTap: (String?) -> Void
    /// Tap-to-analyze hook: an empty-area tap reports the normalized (0...1, top-left)
    /// image point so the caller can segment there. Nil = taps just clear the selection.
    var onTapPoint: ((CGPoint) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fittedRect(imageSize: imageSize, in: geo.size)
            let selected = detections.filter { $0.key == selectedKey }
            ZStack {
                // Empty-area tap: in tap-to-analyze mode report the normalized image point
                // (to segment there); otherwise clear the selection. Taps on existing boxes
                // are left to the boxes' own tap (select/highlight).
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        guard let onTapPoint else { onTap(nil); return }
                        guard fitted.contains(value.location),
                              !detections.contains(where: {
                                  Self.viewRect($0.box, in: fitted).insetBy(dx: -6, dy: -6).contains(value.location)
                              })
                        else { return }
                        onTapPoint(CGPoint(
                            x: (value.location.x - fitted.minX) / fitted.width,
                            y: (value.location.y - fitted.minY) / fitted.height
                        ))
                    })

                // Spotlight: dim the whole photo, punching a hole at each selected box.
                // Skip the dim when the selected row has no detection (e.g. a
                // Document QA field whose OCR didn't find a match) — otherwise we
                // would dim the photo for nothing.
                if selectedKey != nil, !selected.isEmpty {
                    SpotlightDim(container: geo.size, holes: selected.map { Self.viewRect($0.box, in: fitted) })
                        .allowsHitTesting(false)
                }

                // Boxes — selected is bright + accented, the rest fade under the dim.
                ForEach(detections) { detection in
                    let rect = Self.viewRect(detection.box, in: fitted)
                    let isSelected = selectedKey == detection.key
                    let isDimmed = selectedKey != nil && !isSelected
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor : Color.yellow, lineWidth: isSelected ? 3 : 1.5)
                        .shadow(color: isSelected ? Color.accentColor.opacity(0.9) : .clear, radius: 6)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(isDimmed ? 0.12 : 1)
                        .onTapGesture { onTap(detection.key) }
                }

                // Callout beside the selected box, streaming its detail like typing.
                if let anchor = selected.first {
                    CalloutPanel(detection: anchor)
                        .position(Self.calloutPosition(boxRect: Self.viewRect(anchor.box, in: fitted), in: geo.size))
                        .allowsHitTesting(false)
                        .id(anchor.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }

    /// The image's displayed rect after aspect-fit into the container.
    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Map a normalized box (0...1, top-left origin) into the fitted image rect.
    static func viewRect(_ box: CGRect, in fitted: CGRect) -> CGRect {
        CGRect(
            x: fitted.minX + box.minX * fitted.width,
            y: fitted.minY + box.minY * fitted.height,
            width: box.width * fitted.width,
            height: box.height * fitted.height
        )
    }

    /// Place the callout to the right of the box, falling back to left, then center.
    static func calloutPosition(boxRect: CGRect, in size: CGSize) -> CGPoint {
        let width = CalloutPanel.width
        let gap: CGFloat = 12
        let x: CGFloat
        if boxRect.maxX + gap + width <= size.width {
            x = boxRect.maxX + gap + width / 2
        } else if boxRect.minX - gap - width >= 0 {
            x = boxRect.minX - gap - width / 2
        } else {
            x = min(max(width / 2 + 6, boxRect.midX), size.width - width / 2 - 6)
        }
        let y = min(max(74, boxRect.midY), size.height - 74)
        return CGPoint(x: x, y: y)
    }
}

/// A full-photo dim with a rounded hole at each spotlighted box (even-odd fill).
private struct SpotlightDim: View {
    let container: CGSize
    let holes: [CGRect]

    var body: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: container))
            for hole in holes {
                path.addRoundedRect(in: hole.insetBy(dx: -3, dy: -3), cornerSize: CGSize(width: 7, height: 7))
            }
        }
        .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
    }
}

/// The callout shown next to a spotlighted box: a static title plus a body that
/// types itself out one character at a time.
private struct CalloutPanel: View {
    static let width: CGFloat = 210
    let detection: Detection

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(detection.label)
                .font(.caption).bold()
                .foregroundStyle(.white)
            if let detail = detection.detail, !detail.isEmpty {
                TypewriterText(text: detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1))
        .shadow(radius: 8)
    }
}

/// Reveals `text` one character at a time, with a block cursor while typing.
/// Restarts whenever `text` changes (a new selection / a translation landing). The
/// per-character interval matches `Typewriter`, so the auto-tour's dwell stays in sync.
private struct TypewriterText: View {
    let text: String
    @State private var shown = 0

    var body: some View {
        let visible = String(text.prefix(shown))
        let typing = shown < text.count
        return (Text(visible) + Text(typing ? "▌" : "").foregroundColor(.accentColor))
            .animation(nil, value: shown)
            .task(id: text) {
                shown = 0
                let interval = Typewriter.interval(forLength: text.count)
                while shown < text.count {
                    try? await Task.sleep(for: .seconds(interval))
                    if Task.isCancelled { return }
                    shown += 1
                }
            }
    }
}

/// Shared typing cadence. The per-character interval shrinks for long text so the
/// total type time is capped (~3s), keeping the auto-tour snappy on verbose people.
private enum Typewriter {
    static func interval(forLength count: Int) -> Double {
        guard count > 0 else { return 0.022 }
        return min(0.022, 3.0 / Double(count))
    }

    static func duration(forLength count: Int) -> Double {
        Double(count) * interval(forLength: count)
    }
}

// MARK: - Document HUD overlay (sci-fi style label-on-image for document demos).
//
// For document-type demos (Document QA, Receipt, Business Card, ID), every
// detected field is shown on the photo as: a corner-bracket box, a dashed
// connector, and a small label panel above (or below) it that types its value
// out. Labels animate in with a small stagger when a result lands.

private struct DocumentHUDOverlay: View {
    let imageSize: CGSize
    let detections: [Detection]
    let selectedKey: String?
    let onTap: (String?) -> Void

    var body: some View {
        GeometryReader { geo in
            let fitted = SpotlightOverlay.fittedRect(imageSize: imageSize, in: geo.size)
            ZStack {
                // Background tap clears the selection (boxes still highlight).
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(nil) }

                ForEach(Array(detections.enumerated()), id: \.element.id) { index, detection in
                    let rect = SpotlightOverlay.viewRect(detection.box, in: fitted)
                    HUDFieldOverlay(
                        rect: rect,
                        containerSize: geo.size,
                        detection: detection,
                        isSelected: selectedKey == detection.key,
                        appearDelay: 0.06 * Double(index)
                    )
                    .onTapGesture { onTap(detection.key) }
                }
            }
        }
    }
}

/// One field's HUD: corner brackets + a dashed connector + a label panel.
private struct HUDFieldOverlay: View {
    let rect: CGRect
    let containerSize: CGSize
    let detection: Detection
    let isSelected: Bool
    let appearDelay: Double
    @State private var visible = false

    static let panelWidth: CGFloat = 168
    private static let panelEstHeight: CGFloat = 38
    private static let gap: CGFloat = 6

    var body: some View {
        // Place the panel above the box if there's room, else below. Center it
        // on the box midX, clamped to the container width.
        let preferAbove = rect.minY - Self.panelEstHeight - Self.gap >= 4
        let panelMidY = preferAbove
            ? rect.minY - Self.gap - Self.panelEstHeight / 2
            : rect.maxY + Self.gap + Self.panelEstHeight / 2
        let panelMidX = min(max(Self.panelWidth / 2 + 4, rect.midX), containerSize.width - Self.panelWidth / 2 - 4)
        let connectorStart = CGPoint(x: rect.midX, y: preferAbove ? rect.minY : rect.maxY)
        let connectorEnd = CGPoint(x: panelMidX, y: preferAbove ? panelMidY + Self.panelEstHeight / 2 : panelMidY - Self.panelEstHeight / 2)

        let neon: Color = isSelected ? .cyan : Color.cyan.opacity(0.78)

        ZStack {
            CornerBrackets()
                .stroke(neon, lineWidth: isSelected ? 2 : 1.2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .shadow(color: Color.cyan.opacity(isSelected ? 0.85 : 0.35), radius: isSelected ? 6 : 3)

            Path { path in
                path.move(to: connectorStart)
                path.addLine(to: connectorEnd)
            }
            .stroke(neon, style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))

            HUDLabelPanel(detection: detection, isSelected: isSelected)
                .frame(width: Self.panelWidth)
                .position(x: panelMidX, y: panelMidY)
        }
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.94, anchor: .top)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
        .task(id: detection.id) {
            visible = false
            try? await Task.sleep(for: .seconds(appearDelay))
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                visible = true
            }
        }
    }
}

/// Compact two-line label: uppercase mono key, mono value typed out.
private struct HUDLabelPanel: View {
    let detection: Detection
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(detection.label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .tracking(0.8)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail = detection.detail, !detail.isEmpty {
                TypewriterText(text: detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isSelected ? Color.cyan : Color.cyan.opacity(0.55), lineWidth: isSelected ? 1 : 0.6)
        )
        .shadow(color: Color.cyan.opacity(isSelected ? 0.55 : 0.18), radius: isSelected ? 5 : 2)
    }
}

/// Sci-fi corner brackets in place of a full rectangle border.
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let len = min(14, rect.width * 0.28, rect.height * 0.28)
        // top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        // top-right
        path.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        // bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
        // bottom-left
        path.move(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))
        return path
    }
}

/// Renders a `DemoResult`: a big headline, then per-row entries. Tapping a row
/// spotlights its box(es) on the photo (two-way with the overlay).
private struct ResultView: View {
    let result: DemoResult
    /// ROI Zoom only: the overview (stage 1) is still running — show a spinner for it.
    var summaryPending: Bool = false
    let selectedKey: String?
    let onTapKey: (String?) -> Void
    /// Describe & Point: accent the current mention's word in the caption (summary), in
    /// sync with its spotlighted box. Off for other demos (ROI Zoom's overview has no
    /// in-caption mentions to highlight).
    var highlightsCaptionMentions: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ROI Zoom leads with the pinned overview; the count demos lead with the headline.
            if result.summary != nil || summaryPending {
                overviewCard
                if !result.rows.isEmpty {
                    Text("\(result.headline.value) \(result.headline.unit)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(result.headline.value)").font(.system(size: 40, weight: .bold))
                    Text(result.headline.unit).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(result.rows) { row in
                        rowView(row)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The pinned whole-image overview (ROI Zoom stage 1): a spinner while it runs,
    /// then the text, shown above the per-region rows.
    @ViewBuilder private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Overview", systemImage: "doc.text.magnifyingglass")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            if let summary = result.summary {
                Text(highlightsCaptionMentions
                     ? highlightedCaption(summary, detections: result.detections, selectedKey: selectedKey)
                     : AttributedString(summary))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut(duration: 0.35), value: selectedKey)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading the whole image…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func rowView(_ row: AggregateRow) -> some View {
        let isSelected = selectedKey == row.key
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label).fontWeight(.medium)
                Spacer()
                if let trailing = row.trailing {
                    Text(trailing).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTapKey(row.key) }
    }

    // MARK: - Caption mention highlight (Describe & Point)

    /// The caption with the selected mention's word accented, in sync with its box.
    /// Returns the plain caption when nothing is selected or the phrase can't be found
    /// (e.g. a translated caption — the box walk still works, the word highlight is off).
    private func highlightedCaption(_ caption: String, detections: [Detection], selectedKey: String?) -> AttributedString {
        var attr = AttributedString(caption)
        guard let selectedKey,
              let range = Self.mentionRange(in: caption, detections: detections, key: selectedKey)
        else { return attr }
        let lo = caption.distance(from: caption.startIndex, to: range.lowerBound)
        let hi = caption.distance(from: caption.startIndex, to: range.upperBound)
        guard lo < hi else { return attr }
        let aLo = attr.index(attr.startIndex, offsetByCharacters: lo)
        let aHi = attr.index(attr.startIndex, offsetByCharacters: hi)
        attr[aLo..<aHi].backgroundColor = .accentColor.opacity(0.3)
        attr[aLo..<aHi].inlinePresentationIntent = .stronglyEmphasized
        return attr
    }

    /// The caption range of the detection with `key`. Walks detections in caption order,
    /// consuming each phrase left→right (so duplicate phrases map to the right
    /// occurrence) — mirroring how the recipe located them. nil if not found.
    private static func mentionRange(in caption: String, detections: [Detection], key: String) -> Range<String.Index>? {
        var nextStart: [String: String.Index] = [:]
        for detection in detections {
            let phrase = detection.label
            guard !phrase.isEmpty else { continue }
            let lowered = phrase.lowercased()
            let start = nextStart[lowered] ?? caption.startIndex
            guard let range = caption.range(of: phrase, options: .caseInsensitive, range: start..<caption.endIndex) else { continue }
            nextStart[lowered] = range.upperBound
            if detection.key == key { return range }
        }
        return nil
    }
}

// MARK: - Receipt card

/// Bespoke receipt-style display for the Receipt demo: merchant + date header,
/// big currency-aware total, optional subtotal/tax/category/payment chips, a
/// scrollable line-item list, and Copy-CSV / Share-CSV buttons. Reads
/// `ReceiptData` directly (not the generic `DemoResult`), so anything the model
/// couldn't read is simply omitted instead of rendering as "—".
private struct ReceiptCard: View {
    let data: ReceiptData
    /// Temp file the Share button vends. Regenerated on `data` change so the
    /// share sheet always hands off the current scan, not a stale one.
    @State private var csvFile: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            total
            chipsRow
            Divider()
            itemsList
            exportButtons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { regenerateCSVFile() }
        .onChange(of: data) { regenerateCSVFile() }
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(data.merchant ?? "Unknown merchant")
                .font(.headline)
                .lineLimit(2)
            Spacer()
            if let date = data.date {
                Text(date).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var total: some View {
        if let total = data.total {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let currency = data.currency {
                    Text(currency).font(.callout).foregroundStyle(.secondary)
                }
                Text(formatAmount(total))
                    .font(.system(size: 36, weight: .bold))
                    .monospacedDigit()
                Spacer()
                if data.subtotal != nil || data.tax != nil {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let sub = data.subtotal {
                            Text("Subtotal \(formatAmount(sub))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let tax = data.tax {
                            Text("Tax \(formatAmount(tax))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var chipsRow: some View {
        let hasContent = data.category != nil || data.paymentMethod != nil
        if hasContent {
            HStack(spacing: 8) {
                if let category = data.category {
                    Text(category)
                        .font(.caption).bold()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
                if let payment = data.paymentMethod {
                    Label(payment, systemImage: "creditcard")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var itemsList: some View {
        if data.items.isEmpty {
            Text("No line items extracted.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(data.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.name).font(.callout).lineLimit(2)
                            if let q = item.quantity {
                                Text("×\(formatAmount(q))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let amount = item.amount {
                                Text(formatAmount(amount))
                                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder private var exportButtons: some View {
        HStack {
            Button {
                // Copy just the row (no header) so users can append to an
                // existing spreadsheet without duplicating column names.
                UIPasteboard.general.string = Receipt.csvRow(data)
            } label: {
                Label("Copy CSV", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            if let csvFile {
                ShareLink(item: csvFile, preview: SharePreview(csvFile.lastPathComponent)) {
                    Label("Share CSV", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Write the full CSV (header + row) to a temp file so `ShareLink` has a
    /// real .csv URL to hand off — receiving apps (Mail, Files, Numbers) detect
    /// the type from the extension.
    private func regenerateCSVFile() {
        let safeMerchant = (data.merchant ?? "Receipt")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let filename = "\(safeMerchant.isEmpty ? "Receipt" : safeMerchant)-\(data.date ?? "scan").csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try Receipt.csv(data).write(to: url, atomically: true, encoding: .utf8)
            csvFile = url
        } catch {
            csvFile = nil
        }
    }

    /// Presentation-layer formatter for a Receipt amount: integer-valued doubles
    /// without a decimal ("480"), fractional values with two decimals ("12.50"),
    /// nil as empty string. Kept local because formatting is a view concern and
    /// VLMKit's matching helper lives behind module visibility.
    private func formatAmount(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded()
            ? String(Int(value))
            : String(format: "%.2f", value)
    }
}

// MARK: - Business Card card

/// Bespoke contact display for the Business Card demo. Reads `BusinessCardData`
/// directly so missing fields are omitted rather than rendered as "—". The
/// **Save to Contacts** button opens a `CNContactViewController` preview pre-
/// populated from the extraction, so the user can review/edit each field before
/// tapping Done (which writes to Apple Contacts). **Share vCard** vends the
/// same data as a `.vcf` file via `ShareLink` for handoff to Mail / Messages /
/// any third-party contact manager.
private struct BusinessCardCard: View {
    let data: BusinessCardData
    @State private var showContactsPreview = false
    @State private var vcardFile: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            companyAndTitle
            contactMethods
            socialsRow
            addressBlock
            Spacer(minLength: 0)
            exportButtons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { regenerateVCardFile() }
        .onChange(of: data) { regenerateVCardFile() }
        .sheet(isPresented: $showContactsPreview) {
            ContactsPreviewView(data: data, onDismiss: { showContactsPreview = false })
                .ignoresSafeArea()
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(data.displayName.isEmpty ? "Unknown name" : data.displayName)
                .font(.title3).bold()
                .lineLimit(2)
            if let phonetic = data.phoneticName {
                Text(phonetic).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var companyAndTitle: some View {
        let line = [data.title, [data.company, data.department].compactMap { $0 }.joined(separator: " / ").nilIfEmpty]
            .compactMap { $0 }
            .joined(separator: " · ")
        if !line.isEmpty {
            Text(line).font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var contactMethods: some View {
        if !data.phones.isEmpty || !data.emails.isEmpty || !data.urls.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(data.phones.enumerated()), id: \.offset) { _, phone in
                    contactRow(icon: "phone", title: phone.number, badge: phone.kind)
                }
                ForEach(data.emails, id: \.self) { email in
                    contactRow(icon: "envelope", title: email, badge: nil)
                }
                ForEach(data.urls, id: \.self) { url in
                    contactRow(icon: "globe", title: url, badge: nil)
                }
            }
        }
    }

    @ViewBuilder private var socialsRow: some View {
        if !data.socials.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(data.socials.enumerated()), id: \.offset) { _, social in
                    contactRow(icon: "person.crop.circle.badge.plus", title: social.handle, badge: social.platform)
                }
            }
        }
    }

    @ViewBuilder private var addressBlock: some View {
        if let address = data.address {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(address)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func contactRow(icon: String, title: String, badge: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.callout).foregroundStyle(.secondary)
            Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.blue.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var exportButtons: some View {
        HStack {
            Button {
                showContactsPreview = true
            } label: {
                Label("Save to Contacts", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if let vcardFile {
                ShareLink(item: vcardFile, preview: SharePreview(vcardFile.lastPathComponent)) {
                    Label("Share vCard", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Write the vCard to a temp file so `ShareLink` hands off a real `.vcf`
    /// URL — Mail, Files, and Contacts pick the type up from the extension.
    private func regenerateVCardFile() {
        let base = data.displayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let filename = "\(base.isEmpty ? "Contact" : base).vcf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try BusinessCard.vCard(data).write(to: url, atomically: true, encoding: .utf8)
            vcardFile = url
        } catch {
            vcardFile = nil
        }
    }
}

private extension String {
    /// Returns nil when the string is empty, otherwise self. Local helper kept
    /// fileprivate to this view because it's only used to compose the optional
    /// company/department line above.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - ID Document card

/// Bespoke ID-document display: privacy banner up top (loud — IDs are
/// sensitive), face thumbnail from Vision, the typed KYC fields, and the
/// optional MRZ block in monospace. Copy/Share JSON for downstream KYC
/// pipelines; no "Save to Contacts" or vCard — IDs aren't business cards and
/// the export surface stays minimal on purpose.
private struct IDDocumentCard: View {
    let data: IDDocumentData
    let face: CGImage?
    @State private var jsonFile: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            privacyBanner
            headerRow
            primaryRow
            datesRow
            issuingAuthority
            addressBlock
            mrzBlock
            additionalFieldsList
            Spacer(minLength: 0)
            exportButtons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { regenerateJSONFile() }
        .onChange(of: data) { regenerateJSONFile() }
    }

    @ViewBuilder private var privacyBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.green)
            Text("On-device. No data leaves your phone.")
                .font(.caption2).bold()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.green.opacity(0.10), in: Capsule())
    }

    @ViewBuilder private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            facePlaceholder
            VStack(alignment: .leading, spacing: 4) {
                if let type = data.documentType {
                    Text(type)
                        .font(.caption).bold()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
                Text(data.displayName.isEmpty ? "Unknown holder" : data.displayName)
                    .font(.title3).bold()
                    .lineLimit(2)
                if let number = data.documentNumber {
                    Text(number)
                        .font(.callout).monospaced()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var facePlaceholder: some View {
        let side: CGFloat = 88
        Group {
            if let face {
                Image(decorative: face, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.rectangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var primaryRow: some View {
        let parts: [(String, String)] = [
            ("Date of birth", data.dateOfBirth),
            ("Sex", data.sex),
            ("Nationality", data.nationality),
        ].compactMap { label, value in
            value.map { (label, $0) }
        }
        if !parts.isEmpty {
            HStack(spacing: 12) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pair.0).font(.caption2).foregroundStyle(.secondary)
                        Text(pair.1).font(.callout).monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder private var datesRow: some View {
        let issue = data.issueDate.map { ("Issued", $0) }
        let expiry = data.expiryDate.map { ("Expires", $0) }
        let entries = [issue, expiry].compactMap { $0 }
        if !entries.isEmpty {
            HStack(spacing: 12) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, pair in
                    Label("\(pair.0) \(pair.1)", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var issuingAuthority: some View {
        if let authority = data.issuingAuthority {
            HStack(spacing: 6) {
                Image(systemName: "building.columns").font(.caption).foregroundStyle(.secondary)
                Text(authority).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var addressBlock: some View {
        if let address = data.address {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "mappin.and.ellipse").font(.callout).foregroundStyle(.secondary)
                Text(address).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var mrzBlock: some View {
        if let mrz = data.mrz {
            VStack(alignment: .leading, spacing: 3) {
                Text("MRZ").font(.caption2).bold().foregroundStyle(.secondary)
                Text(mrz)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder private var additionalFieldsList: some View {
        if !data.additionalFields.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Additional").font(.caption2).bold().foregroundStyle(.secondary)
                ForEach(Array(data.additionalFields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .firstTextBaseline) {
                        Text(field.label).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(field.value).font(.caption).monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder private var exportButtons: some View {
        HStack {
            Button {
                if let json = try? IDDocument.json(data) {
                    UIPasteboard.general.string = json
                }
            } label: {
                Label("Copy JSON", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            if let jsonFile {
                ShareLink(item: jsonFile, preview: SharePreview(jsonFile.lastPathComponent)) {
                    Label("Share JSON", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Write the JSON to a temp `.json` file so `ShareLink` hands off a real
    /// URL. The filename embeds the document number or display name so the
    /// shared file has a meaningful name (`Passport-X1234567.json` rather than
    /// a UUID).
    private func regenerateJSONFile() {
        let base = (data.documentNumber ?? data.displayName)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let prefix = data.documentType?
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            ?? "ID"
        let filename = "\(prefix.isEmpty ? "ID" : prefix)-\(base.isEmpty ? "scan" : base).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            let json = try IDDocument.json(data)
            try json.write(to: url, atomically: true, encoding: .utf8)
            jsonFile = url
        } catch {
            jsonFile = nil
        }
    }
}

// MARK: - Listing card (multi-turn refinement)

/// Bespoke display for the Listing demo. Renders the generated draft (title,
/// description, features, condition / suggested price chips, tags, alt-text)
/// plus a **Refine** TextField at the bottom that fires a follow-up VLM pass
/// keeping the previous draft as context. **Copy text** flattens the draft to
/// a Mercari-ish "title + description + features" block; **Copy JSON** hands
/// off the structured form for a downstream Shortcut / API.
private struct ListingCard: View {
    let data: ListingData
    let isRefining: Bool
    let hasHeroImage: Bool
    let onRefine: (String) -> Void
    let onGenerateBackground: () -> Void
    let onClearHero: () -> Void
    @State private var instruction = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleBlock
            descriptionBlock
            featuresList
            metaRow
            tagsRow
            altText
            Spacer(minLength: 0)
            backgroundBar
            refineField
            exportButtons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var backgroundBar: some View {
        HStack(spacing: 8) {
            Button(action: onGenerateBackground) {
                Label(
                    hasHeroImage ? "Regenerate background" : "Generate background",
                    systemImage: "wand.and.stars"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            if hasHeroImage {
                Button(action: onClearHero) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .help("Revert to the original photo")
            }
        }
    }

    @ViewBuilder private var titleBlock: some View {
        if let title = data.title {
            Text(title).font(.title3).bold().lineLimit(2)
        } else {
            Text("(no title)").font(.title3).bold().foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var descriptionBlock: some View {
        if let description = data.description {
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var featuresList: some View {
        if !data.features.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(data.features.enumerated()), id: \.offset) { _, feature in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(feature).font(.callout)
                    }
                }
            }
        }
    }

    @ViewBuilder private var metaRow: some View {
        let hasContent = data.condition != nil || data.suggestedPriceRange != nil
        if hasContent {
            HStack(spacing: 8) {
                if let condition = data.condition {
                    Text(condition)
                        .font(.caption).bold()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
                if let price = data.suggestedPriceRange {
                    Label(price, systemImage: "tag")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var tagsRow: some View {
        if !data.tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(data.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var altText: some View {
        if let alt = data.altText {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "text.alignleft").font(.caption2).foregroundStyle(.secondary)
                Text(alt).font(.caption2).foregroundStyle(.secondary).italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var refineField: some View {
        HStack(spacing: 6) {
            TextField("Refine: \"more casual\", \"translate to English\"…", text: $instruction)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(submitRefine)
                .disabled(isRefining)
            if isRefining {
                ProgressView().padding(.horizontal, 4)
            } else {
                Button(action: submitRefine) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder private var exportButtons: some View {
        HStack {
            Button {
                UIPasteboard.general.string = flattenedText(for: data)
            } label: {
                Label("Copy text", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button {
                if let json = try? Listing.json(data) {
                    UIPasteboard.general.string = json
                }
            } label: {
                Label("Copy JSON", systemImage: "curlybraces").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func submitRefine() {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRefine(trimmed)
        instruction = ""
    }

    /// Marketplace-ready "paste this into the listing UI" block. Title on one
    /// line, blank, description, blank, bullet features, blank, "Condition: X
    /// — Price: Y". Plain text so Mercari / eBay / Yahoo Auctions accept it.
    private func flattenedText(for data: ListingData) -> String {
        var blocks: [String] = []
        if let title = data.title { blocks.append(title) }
        if let description = data.description { blocks.append(description) }
        if !data.features.isEmpty {
            blocks.append(data.features.map { "• \($0)" }.joined(separator: "\n"))
        }
        var meta: [String] = []
        if let condition = data.condition { meta.append("Condition: \(condition)") }
        if let price = data.suggestedPriceRange { meta.append("Price: \(price)") }
        if !meta.isEmpty { blocks.append(meta.joined(separator: " — ")) }
        if !data.tags.isEmpty {
            blocks.append(data.tags.map { "#\($0)" }.joined(separator: " "))
        }
        return blocks.joined(separator: "\n\n")
    }
}
