import Foundation
import CoreGraphics
import VLMKit

/// Command-line driver for VLMKit — loads a model on this Mac and runs a recipe
/// on an image. Doubles as the benchmark tool (`bench` prints tokens/sec).
///
/// Usage:
///   vlmkit-cli describe  <image>                       freeform description (streamed)
///   vlmkit-cli describepoint <image> [--max N]         caption + named objects → JSON {caption, objects}
///   vlmkit-cli shelf     <image> [--rows N] [--cols N] α1 shelf inventory → JSON
///   vlmkit-cli crowd     <image> [--max N] [--ask "Q"]  α2 per-person VLM query → JSON
///   vlmkit-cli roizoom   <image> [--rect x,y,w,h] [--ask "Q"] P5 ROI zoom: overview + hi-res detail → JSON
///   vlmkit-cli form      <image> --fields "a,b,c"      α7 form extraction → JSON
///   vlmkit-cli docqa     <image> [--ask "Q"] [--max N] Document QA: auto-extract + free-form Q → JSON
///   vlmkit-cli platereader <image> [--max N]           Plate Reader: read a nameplate/meter → JSON {fields}
///   vlmkit-cli checklist <image> --items "a;b;c"       α11 checklist → JSON
///   vlmkit-cli bench     <image> [--runs N]            decode-speed benchmark
///
/// Global: --model qwen3-4b | qwen3-8b | smolvlm2   (default: qwen3-4b)
@main
struct VLMKitCLI {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            log("Error: \(error)")
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else { return printUsage() }
        let options = Options(Array(arguments.dropFirst()))
        switch command {
        case "describe": try await describe(options)
        case "describepoint": try await describepoint(options)
        case "shelf": try await shelf(options)
        case "crowd": try await crowd(options)
        case "roizoom": try await roizoom(options)
        case "form": try await form(options)
        case "docqa": try await docqa(options)
        case "platereader": try await platereader(options)
        case "checklist": try await checklist(options)
        case "bench": try await bench(options)
        case "help", "-h", "--help": printUsage()
        default:
            log("Unknown command: \(command)\n")
            printUsage()
            exit(1)
        }
    }

    // MARK: - Commands

    static func describe(_ options: Options) async throws {
        let image = try loadImage(options)
        let runner = try await makeRunner(options)
        let prompt = options.string("prompt") ?? "Describe this image in detail."
        for try await chunk in runner.backend.stream(prompt: prompt, images: [image]) {
            FileHandle.standardOutput.write(Data(chunk.utf8))
        }
        print("")
    }

    /// Describe & Point — the VLM writes a caption and names the concrete objects in
    /// it; prints `{caption, objects:[{phrase, query}]}`. Boxes are drawn in-app by the
    /// detector, so this Mac smoke only checks the language: caption reads, phrases are
    /// verbatim spans in caption order, queries are sensible detector nouns.
    static func describepoint(_ options: Options) async throws {
        let image = try loadImage(options)
        let runner = try await makeRunner(options)
        let maxObjects = options.int("max", default: 8)
        log("Describing, then locating up to \(maxObjects) mentioned object(s)…")
        let description = try await DescribeAndPoint.run(on: image, runner: runner, maxObjects: maxObjects)
        struct OutObject: Encodable { let phrase: String; let query: String }
        struct Out: Encodable { let caption: String; let objects: [OutObject] }
        printJSON(Out(
            caption: description.caption,
            objects: description.objects.map { OutObject(phrase: $0.phrase, query: $0.query) }
        ))
    }

    static func shelf(_ options: Options) async throws {
        let image = try loadImage(options)
        let runner = try await makeRunner(options)
        let rows = options.int("rows", default: 3)
        let columns = options.int("cols", default: 3)
        log("Scanning \(rows)×\(columns) tiles…")
        let report = try await ShelfInventory.run(on: image, runner: runner, rows: rows, columns: columns) { done, total in
            log("  tile \(done)/\(total)")
        }
        printJSON(report)
    }

    static func crowd(_ options: Options) async throws {
        let image = try loadImage(options)
        let runner = try await makeRunner(options)
        let maxPeople = options.int("max", default: 24)
        let question = options.string("ask")
        log("Detecting people with Vision, then \(question.map { "asking \"\($0)\"" } ?? "profiling each") with the VLM…")
        let report = try await CrowdAnalytics.run(on: image, runner: runner, maxPeople: maxPeople, question: question) { done, total in
            log("  person \(done)/\(total)")
        }
        printJSON(report)
    }

    static func roizoom(_ options: Options) async throws {
        let image = try loadImage(options)
        let runner = try await makeRunner(options)
        // Normalized ROI rect "x,y,w,h" (each 0...1); default to the center 50%.
        let roi = parseRect(options.string("rect")) ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let question = options.string("ask")
        log("Overview pass (whole image)…")
        let overview = try await ROIZoom.overview(on: image, runner: runner)
        log("Detail pass (ROI \(roi))…")
        let detail = try await ROIZoom.detail(on: image, roi: roi, runner: runner, question: question)
        printJSON(["overview": overview, "detail": detail])
    }

    /// Parse a normalized ROI rect from "x,y,w,h" (each 0...1). Returns nil if malformed.
    static func parseRect(_ string: String?) -> CGRect? {
        guard let parts = string?.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }),
              parts.count == 4,
              let x = Double(parts[0]), let y = Double(parts[1]),
              let w = Double(parts[2]), let h = Double(parts[3]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func form(_ options: Options) async throws {
        let image = try loadImage(options)
        guard let fieldsArg = options.string("fields") else { throw CLIError.missing("--fields \"name1,name2,…\"") }
        let runner = try await makeRunner(options)
        let fields = fieldsArg
            .split(separator: ",")
            .map { FormField(String($0).trimmingCharacters(in: .whitespaces)) }
        let result = try await FormExtraction.extract(fields: fields, from: image, runner: runner)
        printJSON(result)
    }

    /// Document QA — auto-extract every labeled value the VLM can read off the page,
    /// and optionally answer a free-form question about the page in the same run.
    /// Without `--ask`, prints `{fields:[...]}`; with `--ask`, also prints
    /// `{answer, evidence}`. Useful for sanity-checking precision on a target document
    /// before wiring the demo into the iOS app.
    static func docqa(_ options: Options) async throws {
        let image = try loadImage(options)
        let runner = try await makeRunner(options)
        let maxFields = options.int("max", default: 16)
        log("Extracting up to \(maxFields) field(s)…")
        let extraction = try await DocumentQA.extract(on: image, runner: runner, maxFields: maxFields)
        if let question = options.string("ask"), !question.isEmpty {
            log("Asking: \(question)")
            let answer = try await DocumentQA.ask(question, on: image, runner: runner)
            struct AnswerOut: Encodable { let answer: String; let evidence: String? }
            struct Out: Encodable { let fields: [DocumentField]; let question: String; let answer: AnswerOut }
            printJSON(Out(
                fields: extraction.fields,
                question: question,
                answer: AnswerOut(answer: answer.answer, evidence: answer.evidence)
            ))
        } else {
            struct Out: Encodable { let fields: [DocumentField] }
            printJSON(Out(fields: extraction.fields))
        }
    }

    /// Plate Reader — read every reading on a data plate / nameplate / meter / gauge
    /// as `{label, value}` pairs (value required, label inferred when not printed).
    /// In-app YOLOE crops the plate first; this Mac smoke runs the read on the whole
    /// image (pre-crop it yourself) to check that values come back populated.
    static func platereader(_ options: Options) async throws {
        let image = try loadImage(options)
        let runner = try await makeRunner(options)
        let maxFields = options.int("max", default: 16)
        log("Reading plate (up to \(maxFields) field(s))…")
        let fields = try await PlateReader.read(on: image, runner: runner, maxFields: maxFields)
        struct Out: Encodable { let fields: [DocumentField] }
        printJSON(Out(fields: fields))
    }

    static func checklist(_ options: Options) async throws {
        let image = try loadImage(options)
        guard let itemsArg = options.string("items") else { throw CLIError.missing("--items \"req1;req2;…\"") }
        let runner = try await makeRunner(options)
        let items = itemsArg
            .split(separator: ";")
            .enumerated()
            .map { index, requirement in
                ChecklistItem(id: "item\(index + 1)", requirement: String(requirement).trimmingCharacters(in: .whitespaces))
            }
        log("Evaluating \(items.count) checklist item(s)…")
        let report = try await Checklist.evaluate(items: items, on: image, runner: runner) { done, total in
            log("  item \(done)/\(total)")
        }
        printJSON(report)
    }

    static func bench(_ options: Options) async throws {
        let image = try loadImage(options)
        let runner = try await makeRunner(options)
        let runs = options.int("runs", default: 3)
        log("Benchmarking \(runner.backend.profile.displayName) over \(runs) run(s)…")
        var speeds: [Double] = []
        for run in 1...runs {
            let result = try await runner.runText(
                instruction: "Describe this image in detail.",
                images: [image],
                options: GenerationOptions(maxTokens: 200, temperature: 0.0)
            )
            if let stats = result.stats {
                speeds.append(stats.tokensPerSecond)
                log("  run \(run): \(fmt(stats.tokensPerSecond)) tok/s  (\(stats.generatedTokens) tokens, \(fmt(stats.totalSeconds))s)")
            } else {
                log("  run \(run): no stats reported")
            }
        }
        guard !speeds.isEmpty else { return }
        let average = speeds.reduce(0, +) / Double(speeds.count)
        print("\nModel: \(runner.backend.profile.displayName)")
        print("Average decode speed: \(fmt(average)) tok/s over \(speeds.count) run(s)")
    }

    // MARK: - Helpers

    static func profile(_ options: Options) -> ModelProfile {
        switch options.string("model") ?? "" {
        case "qwen3-8b": .qwen3VL8B
        case "smolvlm2": .smolVLM2
        default: .qwen3VL4B
        }
    }

    static func makeRunner(_ options: Options) async throws -> VLMRunner {
        let backend = MLXSwiftBackend(profile: profile(options))
        let localModel = options.string("model-dir").map { URL(fileURLWithPath: $0) }
        log("Loading \(backend.profile.displayName)\(localModel.map { " from \($0.path)" } ?? "")…")
        try await backend.load(from: localModel) { fraction in
            FileHandle.standardError.write(Data("\rDownloading: \(Int(fraction * 100))%   ".utf8))
        }
        log("")
        return VLMRunner(backend: backend)
    }

    static func loadImage(_ options: Options) throws -> VLMImage {
        guard let path = options.imagePath else { throw CLIError.missing("<image>") }
        return try VLMImage(contentsOf: URL(fileURLWithPath: path))
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    static func printUsage() {
        print("""
        VLMKit CLI — structured VLM on Apple Silicon

        USAGE:
          vlmkit-cli describe  <image> [--prompt "..."]      Freeform description (streamed)
          vlmkit-cli describepoint <image> [--max N]         Caption + named objects → JSON {caption, objects}
          vlmkit-cli shelf     <image> [--rows N] [--cols N] α1 Shelf inventory → JSON
          vlmkit-cli crowd     <image> [--max N] [--ask "Q"]  α2 Crowd / per-person query → JSON
          vlmkit-cli roizoom   <image> [--rect x,y,w,h] [--ask "Q"] P5 ROI zoom: overview + hi-res detail → JSON
          vlmkit-cli form      <image> --fields "a,b,c"      α7 Form extraction → JSON
          vlmkit-cli docqa     <image> [--ask "Q"] [--max N] Document QA: auto-extract + free-form Q → JSON
          vlmkit-cli platereader <image> [--max N]           Plate Reader: read a nameplate/meter → JSON {fields}
          vlmkit-cli checklist <image> --items "a;b;c"       α11 Checklist → JSON
          vlmkit-cli bench     <image> [--runs N]            Decode-speed benchmark

        GLOBAL:
          --model qwen3-4b | qwen3-8b | smolvlm2             Model preset (default: qwen3-4b)
          --model-dir <path>                                 Load a local model directory (skips download)

        The model downloads from Hugging Face on first run and is cached.
        Requires an Apple-Silicon Mac (MLX does not run on the iOS Simulator).
        """)
    }
}

/// Minimal positional + `--flag value` argument parser (no external deps).
struct Options {
    private(set) var positional: [String] = []
    private(set) var flags: [String: String] = [:]

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    flags[key] = arguments[index + 1]
                    index += 2
                } else {
                    flags[key] = ""
                    index += 1
                }
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }

    var imagePath: String? { positional.first }
    func string(_ key: String) -> String? { flags[key] }
    func int(_ key: String, default fallback: Int) -> Int { flags[key].flatMap(Int.init) ?? fallback }
}

enum CLIError: Error, CustomStringConvertible {
    case missing(String)
    var description: String {
        switch self {
        case .missing(let what): "missing required argument: \(what)"
        }
    }
}
