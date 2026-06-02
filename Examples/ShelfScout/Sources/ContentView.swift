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
        .task { await vm.loadModelIfNeeded() }
        .sheet(item: $picker) { kind in
            ImagePicker(sourceType: kind.source) { image in
                resetSelection()
                requestRun(.newImage(image))
            }
            .ignoresSafeArea()
        }
        // Translate the model's English answer to Japanese for display.
        .translationTask(outConfig) { session in await translateOutput(using: session) }
        // Translate the Japanese question to English (then run, if a run is pending).
        .translationTask(inConfig) { session in await translateInputThenRun(using: session) }
        .onChange(of: vm.resultCount) { triggerOutputTranslation() }
        .onChange(of: languageRaw) { triggerOutputTranslation() }
        .onChange(of: query) { englishQuery = "" }
    }

    // MARK: - Input (top half) — photo, spotlight overlay, language + tour buttons.

    @ViewBuilder private var imageArea: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image = vm.capturedImage {
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
                    SpotlightOverlay(
                        imageSize: image.size,
                        detections: shown.detections,
                        selectedKey: selectedKey,
                        onTap: handleTap,
                        onTapPoint: vm.selectedDemo.isTapToAnalyze
                            ? { point in Task { await vm.addROI(atNormalizedPoint: point) } }
                            : nil
                    )
                    if !shown.detections.isEmpty {
                        trailingPhotoControls
                    }
                    if vm.selectedDemo.isTapToAnalyze {
                        roiHint(hasRegions: !shown.detections.isEmpty)
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

    // MARK: - Output (bottom half) — demo picker, result, pinned controls.

    @ViewBuilder private var bottomPanel: some View {
        VStack(spacing: 12) {
            demoPicker
            stateContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if showsControls {
                captureControls
            }
        }
        .padding()
    }

    private var demoPicker: some View {
        // Switching the demo reuses the loaded model; it just clears the old result.
        Picker("Demo", selection: Binding(
            get: { vm.selectedDemo.id },
            set: { id in
                guard let demo = vm.demos.first(where: { $0.id == id }) else { return }
                resetSelection()
                vm.select(demo)
            }
        )) {
            ForEach(vm.demos) { demo in
                Text(demo.name).tag(demo.id)
            }
        }
        .pickerStyle(.segmented)
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
            ResultView(
                result: displayed(result),
                summaryPending: vm.roiSummaryPending,
                selectedKey: selectedKey,
                onTapKey: handleTap,
                highlightsCaptionMentions: vm.selectedDemo.id == Demo.describeAndPoint.id
            )
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
                Button { picker = .camera } label: {
                    Label("Camera", systemImage: "camera").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button { picker = .library } label: {
                Label("Photos", systemImage: "photo").frame(maxWidth: .infinity)
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
    }

    // MARK: - Run (with input translation when in Japanese).

    private enum PendingRun {
        case newImage(UIImage)
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
        case .newImage(let image):
            Task { await vm.analyze(image, detail: detail, query: text) }
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
        case camera, library
        var id: Int { hashValue }
        var source: UIImagePickerController.SourceType { self == .camera ? .camera : .photoLibrary }
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
