import Foundation
import CoreML
import CoreVideo
import Accelerate
import CoreImage
import UIKit
import Combine

// Lifted verbatim from the owner's CoreML-Models YOLOEDemo (`ContentView.swift`):
// open-vocabulary text-grounded detection (YOLOE-11s-seg + MobileCLIP). The image
// branch emits per-anchor region embeddings; region↔text similarity is a cached
// matmul in Swift, so changing the query never re-runs the detector. Only the
// detector class and its data types are kept here — the demo's camera/photo/video
// SwiftUI is dropped. The nested `Detection`/`DetectionResult`/`MaskData` types are
// namespaced inside the class so they don't collide with the demo shell's own
// `Detection` (DemoResult.swift). VLMKit stays detector-agnostic; the app owns this.

final class TextGroundingDetector: ObservableObject {
    @Published var isModelLoaded = false

    // MARK: - Result types (nested to avoid colliding with the shell's `Detection`)

    struct Detection: Identifiable {
        let id = UUID()
        let label: String
        let confidence: Float
        let classIndex: Int
        let normRect: CGRect // Normalized [0,1], origin at top-left
        let anchorIndex: Int // Anchor index for mask lookup
    }

    struct MaskData {
        let coeffs: [Float]   // packed [32, numAnchors]
        let protos: [Float]   // packed [32, 160*160]
        let numAnchors: Int
    }

    struct DetectionResult {
        let detections: [Detection]
        let maskData: MaskData?
        /// Combined instance-mask overlay at proto resolution, de-letterboxed to the
        /// original-image aspect (built for the live camera/video paths). nil otherwise.
        var maskImage: CGImage? = nil
    }

    let colors: [UIColor] = [
        .systemRed, .systemGreen, .systemBlue, .systemOrange,
        .systemPurple, .systemYellow, .systemPink, .systemCyan,
    ]

    private var visualModel: MLModel?            // yoloe_detector: image -> boxes, region_embeddings, masks
    private var textEncoder: MLModel?            // Apple mobileclip_blt_text: text[1,77] -> final_emb_1[1,512]
    private var reprtaModel: MLModel?            // YOLOE reprta: raw_tpe[1,80,512] -> tpe[1,80,512]
    private var tokenizer: CLIPTokenizer?

    private let embedDim = 512
    private let augDim = 513                      // embed + 1 (bias channel of the contrastive head)
    private let reprtaSlots = 80                  // reprta input is a fixed [1,80,512] buffer
    private let numAnchors = 8400
    private let inputSize = 640
    var confidenceThreshold: Float = 0.15
    private let nmsThreshold: Float = 0.5
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var imageArray: MLMultiArray?
    private var cachedQueryString = ""
    private(set) var cachedQueries: [String] = []
    /// Cached text embeddings, row-major [N, 513] = [normalize(reprta(clip)), 1.0].
    /// Per-frame similarity is logit = textPrime · region', score = sigmoid(logit),
    /// which reproduces YOLOE's BNContrastiveHead exactly.
    private var cachedTextPrime: [Float] = []

    /// Last mask data from the most recent detection (for threshold re-rendering)
    var lastMaskData: MaskData?

    init() {
        loadModels()
    }

    private func loadModels() {
        do {
            guard let d = Bundle.main.url(forResource: "yoloe_detector", withExtension: "mlmodelc"),
                  let e = Bundle.main.url(forResource: "mobileclip_blt_text", withExtension: "mlmodelc"),
                  let r = Bundle.main.url(forResource: "reprta", withExtension: "mlmodelc"),
                  let v = Bundle.main.url(forResource: "clip_vocab", withExtension: "json") else {
                print("[YOLOE] Missing model files")
                return
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            visualModel = try MLModel(contentsOf: d, configuration: config)
            textEncoder = try MLModel(contentsOf: e, configuration: config)
            reprtaModel = try MLModel(contentsOf: r, configuration: config)
            tokenizer = try CLIPTokenizer(vocabularyURL: v)
            DispatchQueue.main.async { self.isModelLoaded = true }
        } catch {
            print("[YOLOE] Model load failed: \(error)")
        }
    }

    // MARK: - Text Encoding

    func updateQueries(_ queryString: String) {
        guard queryString != cachedQueryString else { return }
        cachedQueryString = queryString

        let queries = queryString.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        guard !queries.isEmpty, let textEncoder, let reprtaModel, let tokenizer else {
            cachedQueries = []; cachedTextPrime = []; return
        }
        let n = min(queries.count, reprtaSlots)
        cachedQueries = Array(queries.prefix(n))

        do {
            // 1) Encode each query with Apple's MobileCLIP, L2-normalize, and pack
            //    into the fixed [1, 80, 512] reprta input buffer.
            let rawTpe = try MLMultiArray(shape: [1, reprtaSlots as NSNumber, embedDim as NSNumber], dataType: .float32)
            let rawPtr = rawTpe.dataPointer.bindMemory(to: Float32.self, capacity: reprtaSlots * embedDim)
            memset(rawPtr, 0, reprtaSlots * embedDim * 4)

            for (i, query) in cachedQueries.enumerated() {
                let tokens = tokenizer.tokenize(query)
                let tokenArray = try MLMultiArray(shape: [1, tokenizer.contextLength as NSNumber], dataType: .int32)
                let tokenPtr = tokenArray.dataPointer.bindMemory(to: Int32.self, capacity: tokenizer.contextLength)
                for j in 0..<tokenizer.contextLength { tokenPtr[j] = Int32(tokens[j]) }

                let input = try MLDictionaryFeatureProvider(dictionary: ["text": MLFeatureValue(multiArray: tokenArray)])
                let output = try textEncoder.prediction(from: input)
                guard let embMA = output.featureValue(for: "final_emb_1")?.multiArrayValue else { continue }

                let emb = readFloat(embMA)
                var norm: Float = 0
                vDSP_svesq(emb, 1, &norm, vDSP_Length(Int(embedDim)))
                norm = sqrt(norm)
                if norm > 1e-8 {
                    for j in 0..<embedDim { rawPtr[i * embedDim + j] = emb[j] / norm }
                }
            }

            // 2) RepRTA residual MLP (raw_tpe -> tpe). Normalization is done here.
            let reprtaInput = try MLDictionaryFeatureProvider(dictionary: ["raw_tpe": MLFeatureValue(multiArray: rawTpe)])
            let reprtaOutput = try reprtaModel.prediction(from: reprtaInput)
            guard let tpeMA = reprtaOutput.featureValue(for: "tpe")?.multiArrayValue else {
                cachedTextPrime = []; return
            }
            let tpe = readFloat(tpeMA)  // [1, 80, 512]

            // 3) Build text' = [normalize(tpe), 1.0] -> row-major [N, 513].
            var textPrime = [Float](repeating: 0, count: n * augDim)
            for i in 0..<n {
                let off = i * embedDim
                var norm: Float = 0
                tpe.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + off, 1, &norm, vDSP_Length(Int(embedDim))) }
                let inv: Float = norm > 1e-8 ? 1.0 / sqrt(norm) : 0
                for c in 0..<embedDim { textPrime[i * augDim + c] = tpe[off + c] * inv }
                textPrime[i * augDim + embedDim] = 1.0  // bias channel multiplier
            }
            cachedTextPrime = textPrime
        } catch {
            cachedQueries = []; cachedTextPrime = []
        }
    }

    // MARK: - Sync Detection (camera / video -- boxes + combined mask overlay)

    func detectSync(pixelBuffer: CVPixelBuffer) -> DetectionResult {
        guard let cgImage = cgImageFromPixelBuffer(pixelBuffer) else {
            return DetectionResult(detections: [], maskData: nil)
        }
        return runDetection(cgImage: cgImage, needMasks: true, maskTopOnePerClass: false)
    }

    func detectSync(image: UIImage) -> DetectionResult {
        guard let cgImage = normalizedCGImage(image) else {
            return DetectionResult(detections: [], maskData: nil)
        }
        return runDetection(cgImage: cgImage, needMasks: true, maskTopOnePerClass: false)
    }

    // MARK: - Detection with Masks (for photo mode)

    /// `maskTopOnePerClass` keeps only the highest-confidence detection per class in the
    /// combined mask overlay. Used by Describe & Point, where the caller also reduces
    /// boxes to top-1-per-class — without this, low-confidence runs paint repeated
    /// same-color blobs for the same noun.
    func detectSyncWithMasks(image: UIImage, maskTopOnePerClass: Bool = false) -> DetectionResult {
        guard let cgImage = normalizedCGImage(image) else { return DetectionResult(detections: [], maskData: nil) }
        let result = runDetection(cgImage: cgImage, needMasks: true, maskTopOnePerClass: maskTopOnePerClass)
        lastMaskData = result.maskData
        return result
    }

    private func cgImageFromPixelBuffer(_ pb: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pb)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    // MARK: - Core Detection

    private func runDetection(cgImage: CGImage, needMasks: Bool, maskTopOnePerClass: Bool) -> DetectionResult {
        // Snapshot the text cache so a concurrent updateQueries() can't tear it.
        let textPrime = cachedTextPrime
        let queries = cachedQueries
        guard let visualModel, !textPrime.isEmpty, queries.count == textPrime.count / augDim else {
            return DetectionResult(detections: [], maskData: nil)
        }
        let n = queries.count

        do {
            let (tensor, imgW, imgH, padX, padY, scale) = try preprocessImage(cgImage)
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: tensor)])
            let output = try visualModel.prediction(from: input)

            guard let boxesMA = output.featureValue(for: "boxes")?.multiArrayValue,
                  let regionMA = output.featureValue(for: "region_embeddings")?.multiArrayValue else {
                return DetectionResult(detections: [], maskData: nil)
            }

            // boxes [4, 8400] (xywh @640) and region' [513, 8400], packed FP32.
            let boxes = readMatrix2D(boxesMA)
            let region = readMatrix2D(regionMA)

            // logits [n, 8400] = textPrime [n, 513] x region' [513, 8400].
            // This reproduces YOLOE's BNContrastiveHead exactly; score = sigmoid(logit).
            var logits = [Float](repeating: 0, count: n * numAnchors)
            textPrime.withUnsafeBufferPointer { aP in
                region.withUnsafeBufferPointer { bP in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                                Int32(n), Int32(numAnchors), Int32(augDim),
                                1.0, aP.baseAddress, Int32(augDim),
                                bP.baseAddress, Int32(numAnchors),
                                0.0, &logits, Int32(numAnchors))
                }
            }

            // Threshold on the logit so sigmoid is only evaluated for survivors.
            let t = confidenceThreshold
            let logitThresh: Float = (t > 0 && t < 1) ? log(t / (1 - t)) : -.greatestFiniteMagnitude
            let invW = 1.0 / (Float(imgW) * scale)
            let invH = 1.0 / (Float(imgH) * scale)

            var allDets: [(CGRect, Float, Int, Int)] = []  // rect, score, classIdx, anchorIdx
            for k in 0..<n {
                let off = k * numAnchors
                for a in 0..<numAnchors {
                    let logit = logits[off + a]
                    guard logit >= logitThresh else { continue }
                    let score = 1.0 / (1.0 + exp(-logit))

                    let cx = boxes[a], cy = boxes[numAnchors + a]
                    let bw = boxes[2 * numAnchors + a], bh = boxes[3 * numAnchors + a]
                    let nx = (cx - bw / 2 - padX) * invW
                    let ny = (cy - bh / 2 - padY) * invH
                    let rect = CGRect(
                        x: CGFloat(max(0, min(1, nx))),
                        y: CGFloat(max(0, min(1, ny))),
                        width: CGFloat(max(0, min(1, bw * invW))),
                        height: CGFloat(max(0, min(1, bh * invH)))
                    )
                    allDets.append((rect, score, k, a))
                }
            }

            // Per-class NMS.
            allDets.sort { $0.1 > $1.1 }
            var kept: [Int] = []
            for i in allDets.indices {
                var suppress = false
                for ki in kept where allDets[i].2 == allDets[ki].2 {
                    if iou(allDets[i].0, allDets[ki].0) > nmsThreshold { suppress = true; break }
                }
                if !suppress { kept.append(i) }
            }

            let detections = kept.prefix(50).map { i in
                Detection(label: queries[allDets[i].2],
                          confidence: allDets[i].1,
                          classIndex: allDets[i].2,
                          normRect: allDets[i].0,
                          anchorIndex: allDets[i].3)
            }

            var maskData: MaskData? = nil
            var maskImage: CGImage? = nil
            if needMasks,
               let coeffsMA = output.featureValue(for: "mask_coeffs")?.multiArrayValue,
               let protosMA = output.featureValue(for: "mask_protos")?.multiArrayValue {
                let md = MaskData(coeffs: readMatrix2D(coeffsMA),
                                  protos: readProtos(protosMA),
                                  numAnchors: numAnchors)
                maskData = md
                let maskDets: [Detection]
                if maskTopOnePerClass {
                    var best: [Int: Detection] = [:]
                    for d in detections {
                        if let cur = best[d.classIndex], cur.confidence >= d.confidence { continue }
                        best[d.classIndex] = d
                    }
                    maskDets = Array(best.values)
                } else {
                    maskDets = detections
                }
                maskImage = buildCombinedMask(maskDets, md,
                                              padX: padX, padY: padY, scale: scale,
                                              imgW: imgW, imgH: imgH)
            }
            return DetectionResult(detections: detections, maskData: maskData, maskImage: maskImage)
        } catch {
            return DetectionResult(detections: [], maskData: nil)
        }
    }

    // MARK: - Preprocessing

    private func preprocessImage(_ cgImage: CGImage) throws
        -> (MLMultiArray, Int, Int, Float, Float, Float)
    {
        let imgW = cgImage.width, imgH = cgImage.height
        let scale = Float(inputSize) / Float(max(imgW, imgH))
        let scaledW = Int(Float(imgW) * scale)
        let scaledH = Int(Float(imgH) * scale)
        let padX = (inputSize - scaledW) / 2
        let padY = (inputSize - scaledH) / 2

        // Use UIGraphicsImageRenderer (UIKit y-down coordinates) to avoid
        // CGContext's y-up coordinate system flipping the image.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: inputSize, height: inputSize))
        let uiImage = renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: inputSize, height: inputSize))
            UIImage(cgImage: cgImage).draw(in: CGRect(x: padX, y: padY, width: scaledW, height: scaledH))
        }
        guard let rendered = uiImage.cgImage else { throw NSError(domain: "Preprocess", code: 1) }
        guard let ctx = CGContext(
            data: nil, width: inputSize, height: inputSize,
            bitsPerComponent: 8, bytesPerRow: inputSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw NSError(domain: "Preprocess", code: 2) }
        ctx.draw(rendered, in: CGRect(x: 0, y: 0, width: inputSize, height: inputSize))
        guard let pixels = ctx.data else { throw NSError(domain: "Preprocess", code: 3) }

        if imageArray == nil {
            imageArray = try MLMultiArray(
                shape: [1, 3, inputSize as NSNumber, inputSize as NSNumber], dataType: .float32)
        }
        let dst = imageArray!.dataPointer.bindMemory(to: Float32.self, capacity: 3 * inputSize * inputSize)
        let src = pixels.bindMemory(to: UInt8.self, capacity: inputSize * inputSize * 4)

        let hw = inputSize * inputSize
        let inv: Float = 1.0 / 255.0
        for i in 0..<hw {
            dst[0 * hw + i] = Float(src[i * 4 + 0]) * inv
            dst[1 * hw + i] = Float(src[i * 4 + 1]) * inv
            dst[2 * hw + i] = Float(src[i * 4 + 2]) * inv
        }

        return (imageArray!, imgW, imgH, Float(padX), Float(padY), scale)
    }

    /// Normalize UIImage orientation so cgImage matches the displayed orientation.
    private func normalizedCGImage(_ image: UIImage) -> CGImage? {
        guard image.imageOrientation != .up else { return image.cgImage }
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalized?.cgImage
    }

    // MARK: - Helpers

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let interX = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let interY = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let inter = Float(interX * interY)
        let union = Float(a.width * a.height) + Float(b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }

    private func readFloat(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        var result = [Float](repeating: 0, count: count)
        if array.dataType == .float16 {
            let ptr = array.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<count { result[i] = Float(ptr[i]) }
        } else {
            let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<count { result[i] = ptr[i] }
        }
        return result
    }

    /// Read an MLMultiArray whose trailing two dims are [rows, cols] into a packed
    /// row-major FP32 buffer, de-padding ANE row alignment. FP16 outputs are bulk
    /// converted with vImage -- never element-by-element (see conversion notes:
    /// boxing 4M FP16 values per frame costs ~170 ms).
    private func readMatrix2D(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map { $0.intValue }
        let strides = a.strides.map { $0.intValue }
        let rows = shape[shape.count - 2]
        let cols = shape[shape.count - 1]
        let rowStride = strides[strides.count - 2]
        let colStride = strides[strides.count - 1]
        var out = [Float](repeating: 0, count: rows * cols)

        if colStride == 1 {
            out.withUnsafeMutableBufferPointer { dst in
                if a.dataType == .float16 {
                    var s = vImage_Buffer(data: a.dataPointer, height: vImagePixelCount(rows),
                                          width: vImagePixelCount(cols), rowBytes: rowStride * 2)
                    var d = vImage_Buffer(data: UnsafeMutableRawPointer(dst.baseAddress!),
                                          height: vImagePixelCount(rows),
                                          width: vImagePixelCount(cols), rowBytes: cols * 4)
                    vImageConvert_Planar16FtoPlanarF(&s, &d, vImage_Flags(0))
                } else {
                    let src = a.dataPointer.assumingMemoryBound(to: Float32.self)
                    for r in 0..<rows { memcpy(dst.baseAddress! + r * cols, src + r * rowStride, cols * 4) }
                }
            }
        } else {  // general strided fallback
            if a.dataType == .float16 {
                let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
                for r in 0..<rows { for c in 0..<cols { out[r * cols + c] = Float(p[r * rowStride + c * colStride]) } }
            } else {
                let p = a.dataPointer.assumingMemoryBound(to: Float32.self)
                for r in 0..<rows { for c in 0..<cols { out[r * cols + c] = p[r * rowStride + c * colStride] } }
            }
        }
        return out
    }

    /// Read mask protos [1, C, H, W] into packed [C, H*W] FP32, handling ANE padding.
    private func readProtos(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map { $0.intValue }
        let strides = a.strides.map { $0.intValue }
        let c = shape[1], h = shape[2], w = shape[3]
        let sc = strides[1], sh = strides[2], sw = strides[3]
        var out = [Float](repeating: 0, count: c * h * w)

        if sw == 1 && sh == w {  // contiguous rows; channels may still be padded
            out.withUnsafeMutableBufferPointer { dst in
                if a.dataType == .float16 {
                    var s = vImage_Buffer(data: a.dataPointer, height: vImagePixelCount(c),
                                          width: vImagePixelCount(h * w), rowBytes: sc * 2)
                    var d = vImage_Buffer(data: UnsafeMutableRawPointer(dst.baseAddress!),
                                          height: vImagePixelCount(c),
                                          width: vImagePixelCount(h * w), rowBytes: h * w * 4)
                    vImageConvert_Planar16FtoPlanarF(&s, &d, vImage_Flags(0))
                } else {
                    let src = a.dataPointer.assumingMemoryBound(to: Float32.self)
                    for ch in 0..<c { memcpy(dst.baseAddress! + ch * h * w, src + ch * sc, h * w * 4) }
                }
            }
        } else {  // general strided fallback
            if a.dataType == .float16 {
                let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
                for ch in 0..<c { for y in 0..<h {
                    let base = ch * sc + y * sh, o = (ch * h + y) * w
                    for x in 0..<w { out[o + x] = Float(p[base + x * sw]) }
                } }
            } else {
                let p = a.dataPointer.assumingMemoryBound(to: Float32.self)
                for ch in 0..<c { for y in 0..<h {
                    let base = ch * sc + y * sh, o = (ch * h + y) * w
                    for x in 0..<w { out[o + x] = p[base + x * sw] }
                } }
            }
        }
        return out
    }

    // MARK: - Combined instance-mask overlay (yolo-ios-app fast method)

    /// Build one proto-resolution RGBA overlay for all detections in a single BLAS matmul
    /// (coeffs[N,32] x protos[32,HW]), composite per-bbox lowest-score-first, then crop out
    /// the letterbox so the result matches the original-image aspect. nil if no detections.
    private func buildCombinedMask(_ dets: [Detection], _ md: MaskData,
                                   padX: Float, padY: Float, scale: Float,
                                   imgW: Int, imgH: Int) -> CGImage? {
        let n = dets.count
        guard n > 0 else { return nil }
        let mc = 32, mw = 160, mh = 160, hw = mw * mh

        // Gather coeffs A[n,32] for the kept anchors, then combined[n,hw] = A x protos.
        var a = [Float](repeating: 0, count: n * mc)
        for (i, d) in dets.enumerated() {
            for k in 0..<mc { a[i * mc + k] = md.coeffs[k * md.numAnchors + d.anchorIndex] }
        }
        var comb = [Float](repeating: 0, count: n * hw)
        a.withUnsafeBufferPointer { aP in
            md.protos.withUnsafeBufferPointer { bP in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                            Int32(n), Int32(hw), Int32(mc),
                            1.0, aP.baseAddress, Int32(mc),
                            bP.baseAddress, Int32(hw),
                            0.0, &comb, Int32(hw))
            }
        }

        // Composite into one proto-res RGBA buffer (lowest score first -> highest on top).
        var px = [UInt8](repeating: 0, count: hw * 4)
        let s160 = Float(mw) / Float(inputSize)      // 160 / 640
        let order = dets.indices.sorted { dets[$0].confidence < dets[$1].confidence }
        for i in order {
            let d = dets[i], r = d.normRect
            // original-normalized box -> 640 letterbox -> 160 proto space
            let x0 = (Float(r.minX) * Float(imgW) * scale + padX) * s160
            let y0 = (Float(r.minY) * Float(imgH) * scale + padY) * s160
            let x1 = (Float(r.maxX) * Float(imgW) * scale + padX) * s160
            let y1 = (Float(r.maxY) * Float(imgH) * scale + padY) * s160
            let bx0 = max(0, min(mw - 1, Int(x0))), bx1 = max(0, min(mw - 1, Int(x1)))
            let by0 = max(0, min(mh - 1, Int(y0))), by1 = max(0, min(mh - 1, Int(y1)))
            guard bx1 >= bx0, by1 >= by0 else { continue }
            let (cr, cg, cb) = rgbComponents(colors[d.classIndex % colors.count])
            let base = i * hw
            for y in by0...by1 {
                let row = y * mw
                for x in bx0...bx1 where comb[base + row + x] > 0 {  // logit>0 == sigmoid>0.5
                    let o = (row + x) * 4
                    px[o] = cr; px[o + 1] = cg; px[o + 2] = cb; px[o + 3] = 255
                }
            }
        }

        guard let full = makeRGBA(px, mw, mh) else { return nil }
        // De-letterbox so the overlay matches the original frame (shown with the same gravity).
        let cx = Int((padX * s160).rounded()), cy = Int((padY * s160).rounded())
        let cw = Int((Float(imgW) * scale * s160).rounded())
        let ch = Int((Float(imgH) * scale * s160).rounded())
        let crop = CGRect(x: cx, y: cy, width: max(1, min(cw, mw - cx)), height: max(1, min(ch, mh - cy)))
        return full.cropping(to: crop) ?? full
    }

    private func rgbComponents(_ c: UIColor) -> (UInt8, UInt8, UInt8) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt8(max(0, min(1, r)) * 255), UInt8(max(0, min(1, g)) * 255), UInt8(max(0, min(1, b)) * 255))
    }

    private func makeRGBA(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: cs, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
