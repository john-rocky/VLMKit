# VLMKit

> **Structured VLM for Apple Silicon.**
> Give your vision-language model a finger to point with, eyes to count with, and a memory to remember with — by structuring multiple VLM calls with Vision, CoreML, ARKit, and LiDAR.

<!-- TODO(owner): add a 5–15s demo GIF here (shelf scan → JSON), and a linear-scaling benchmark chart. -->

VLMs are great at *describing* a scene but weak at **counting** (≥3 objects → large error), **locating precisely**, **remembering across time**, and **reading fine detail in high-resolution images**. Apple's on-device frameworks are excellent at exactly those things but have no semantic understanding. **VLMKit is the structural glue**: it decomposes an input with Apple frameworks, fans out N VLM calls, and aggregates the results into precise structured output — 100% on device.

```
One VLM query  ──▶  decompose (Vision / grid / LiDAR)  ──▶  N VLM calls  ──▶  aggregate  ──▶  typed result
```

> **Status:** Phase 1 — core framework, the MLX backend, and Genre α (image fan-out) recipes **α1 / α7 / α11**. See the [roadmap](#roadmap).

---

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/<owner>/VLMKit", from: "0.1.0")
```

Then add `VLMKit` to your target. Requires **iOS 17 / iPadOS 17 / macOS 14 / visionOS 1**, an **Apple-Silicon** device, and Xcode 16 (Swift 6.1 toolchain). Inference uses [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm); models download from Hugging Face on first run and are cached.

## Quick start

```swift
import VLMKit

// Load a model (downloads on first run, then cached).
let backend = MLXSwiftBackend(profile: .qwen3VL4B)
try await backend.load()
let runner = VLMRunner(backend: backend)

// Run a recipe.
let image  = try VLMImage(contentsOf: shelfPhotoURL)
let report = try await ShelfInventory.run(on: image, runner: runner)

print(report.totalCount)   // 42
print(report.items)        // [ShelfItemCount(name: "Coke", count: 8), …]
```

## Recipes (Genre α — image fan-out)

### α1 — Shelf inventory
Tiles the image, lists products per tile, aggregates counts. Region-axis fan-out: per-tile crops give the VLM more effective resolution, and splitting the count avoids the "count many objects at once" failure mode.

```swift
let report = try await ShelfInventory.run(on: image, runner: runner, rows: 3, columns: 3) { done, total in
    print("tile \(done)/\(total)")
}
```

### α7 — Form / document extraction
One typed call returns a value per requested field.

```swift
let fields = [
    FormField("invoice_number"),
    FormField("total", description: "grand total with currency"),
    FormField("date"),
]
let values = try await FormExtraction.extract(fields: fields, from: image, runner: runner)
// ["invoice_number": "INV-2031", "total": "$1,240.00", "date": "2026-05-01"]
```

### α11 — Multi-item checklist
Task-axis fan-out: each requirement is judged in its own call against the same image, so verdicts stay independent and each carries a reason. This is the basis for the compliance (ζ) recipes.

```swift
let items = [
    ChecklistItem(id: "ppe_helmet", requirement: "Every worker is wearing a hard hat."),
    ChecklistItem(id: "exit_clear", requirement: "The fire exit is not blocked."),
]
let report = try await Checklist.evaluate(items: items, on: image, runner: runner)
print(report.passedCount, "/", report.total)
```

### Compose your own
Every recipe is built from the same primitives. A custom region-fan-out pipeline:

```swift
let pipeline = FanoutPipeline(
    extractor: GridExtractor(rows: 3, columns: 3, overlap: 0.1),   // or VisionObjectExtractor / FullImageExtractor
    runner: runner,
    makeTask: { _ in
        VLMTask<[ShelfProduct]>(
            instruction: "List the products visible in this tile.",
            jsonHint: #"[{"name": "string", "brand": "string or null"}]"#
        )
    },
    aggregator: CountAggregator { $0.name.lowercased() }
)
let counts = try await pipeline.run(on: image)
```

## CLI

A macOS command-line tool to try recipes and benchmark, with no app required:

```bash
swift run vlmkit-cli describe       photo.jpg
swift run vlmkit-cli describepoint  photo.jpg --max 8
swift run vlmkit-cli shelf          shelf.jpg --rows 3 --cols 3
swift run vlmkit-cli form           invoice.jpg --fields "invoice_number,total,date"
swift run vlmkit-cli checklist      site.jpg   --items "Workers wear hard hats; Fire exit is clear"
swift run vlmkit-cli bench          shelf.jpg  --runs 5 --model qwen3-4b
```

`describepoint` returns the **Describe & Point** recipe's JSON
(`{caption, objects:[{phrase, query}]}`) — the VLM-only half of the demo. Boxes
are produced by an on-device detector in the example app, not in the recipe.

## Models

| Preset | Hugging Face repo | ~Memory | Use when |
| --- | --- | --- | --- |
| `.qwen3VL4B` *(default)* | `lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit` | ~3 GB | best accuracy/size balance, broad device support |
| `.qwen3VL8B` | `mlx-community/Qwen3-VL-8B-Instruct-4bit` ¹ | ~6 GB | higher accuracy, M-series Macs / 16 GB+ iPad |
| `.smolVLM2` | `HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx` | ~1 GB | fastest, fits 8 GB iPhones |

Any other MLX-format VLM repo works too — construct a `ModelProfile` with its repo id.

¹ Verify this repo id on Hugging Face for your target and swap if needed; it is referenced by string, not pinned.

## Architecture

```
Layer 3  Showcase apps                     (sales demos — not in this package)
Layer 2  Recipes          ShelfInventory · FormExtraction · Checklist · …
Layer 1  Core framework   RegionExtractor · VLMRunner · Aggregator · FanoutPipeline
                          VLMBackend · ModelProfile · VLMCapabilities
```

| Primitive | Role |
| --- | --- |
| `RegionExtractor` | decide *where* to look — `FullImageExtractor`, `GridExtractor`, `VisionObjectExtractor` |
| `VLMTask<Output>` | one typed VLM call (instruction + the `Decodable` it produces) |
| `VLMRunner` | run a task: compose prompt → generate → extract JSON → decode → retry |
| `Aggregator` | reduce per-call results — `ListAggregator`, `CountAggregator` |
| `FanoutPipeline` | `extractor → crop + task per region → aggregator`, end to end |
| `VLMBackend` | inference seam — `MLXSwiftBackend` today; CoreML / Foundation / remote later |

## Benchmarking

Decode speed is reported per generation (`GenerationResult.stats.tokensPerSecond`). Reproduce with:

```bash
swift run vlmkit-cli bench shelf.jpg --runs 5 --model qwen3-4b
```

<!-- TODO(owner): publish numbers on real hardware (the Simulator can't run MLX). -->

| Model | M3 | M4 | M5 | iPhone 17 Pro |
| --- | --- | --- | --- | --- |
| Qwen3-VL-4B 4-bit | _tok/s_ | _tok/s_ | _tok/s_ | _tok/s_ |
| SmolVLM2 500M | _tok/s_ | _tok/s_ | _tok/s_ | _tok/s_ |

## Limitations (Phase 1)

- **Apple Silicon only.** MLX needs a real device or Apple-Silicon Mac — it does **not** run on the iOS Simulator.
- **Structured output is prompt-guided.** The MLX Swift backend has no JSON-schema/grammar-constrained decoding, so VLMKit asks for JSON, extracts it from the response, and decodes it, with one automatic retry on failure. Robust in practice, not guaranteed.
- **Fan-out is sequential.** Calls run one at a time through a single GPU model, so latency ≈ N × per-call. This matches what the hardware does; it is not parallel batching.
- **Genre α only.** Visual diff (β), video (γ, δ), spatial AR (ε), and compliance (ζ) are on the roadmap.

## Roadmap

- **Phase 1 ✓** Core + MLX backend + Genre α recipes α1 / α7 / α11
- **Phase 2** Saturate Genre α (α2–α10)
- **Phase 3** Genre β visual diff · `CoreMLBackend`
- **Phase 4** Genre γ video indexing (SQLite + embeddings + search)
- **Phase 5** Genre δ video narrative
- **Phase 6** Genre ε spatial AR (ARKit + LiDAR)
- **Phase 7** Genre ζ anomaly / compliance · `AppleFoundationBackend`

## License

MIT — see [LICENSE](LICENSE). Model weights carry their own licenses.
