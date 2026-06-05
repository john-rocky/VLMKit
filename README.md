# VLMKit

> **Structured VLM for Apple Silicon.**
> Give your vision-language model a finger to point with, eyes to count with, and a memory to remember with — by structuring multiple VLM calls with Vision, CoreML, ARKit, and LiDAR.

<p align="center">
  <img src="https://github.com/user-attachments/assets/b7e18fe1-bbf2-4cd2-8f64-542e2279cc8d" width="200" alt="Describe & Point" />
  <img src="https://github.com/user-attachments/assets/2f985602-ed5f-438e-af36-e565d3be3e7f" width="200" alt="Crowd Analytics" />
  <img src="https://github.com/user-attachments/assets/96158444-1bb0-4427-a468-efe027dd8b21" width="200" alt="Business Card" />
  <img src="https://github.com/user-attachments/assets/ad80bfb1-d45d-4402-82d7-bc03904b761c" width="200" alt="AR Measure" />
</p>

<!-- TODO(owner): linear-scaling benchmark chart. -->

VLMs are great at *describing* a scene but weak at **counting** (≥3 objects → large error), **locating precisely**, **remembering across time**, and **reading fine detail in high-resolution images**. Apple's on-device frameworks are excellent at exactly those things but have no semantic understanding. **VLMKit is the structural glue**: it decomposes an input with Apple frameworks, fans out N VLM calls, and aggregates the results into precise structured output — 100% on device.

```
One VLM query  ──▶  decompose (Vision / grid / LiDAR)  ──▶  N VLM calls  ──▶  aggregate  ──▶  typed result
```

> **Status:** Phase 1 — core framework, the MLX backend, and Genre α (image fan-out) recipes. See the [roadmap](#roadmap).

---

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/john-rocky/VLMKit", from: "0.1.0")
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

## Recipes

Every recipe is a thin layer over the [core primitives](#architecture). Pick one that matches your shape, or [compose your own](#compose-your-own).

### Document QA

Auto-extract every labeled value off any printed page (machine plate, invoice,
receipt, business card, form, contract) into key/value pairs, and answer
free-form questions about it. The free-form pass is a second call so callers
can cache the extraction and re-ask without re-reading the whole page.

```swift
let extraction = try await DocumentQA.extract(on: image, runner: runner)
// extraction.fields → [DocumentField("Model Number", "XJ-100A"), DocumentField("Date", "2026-06-01"), …]

let answer = try await DocumentQA.ask("What is the frame number?", on: image, runner: runner)
// answer.answer    → "XJ-100A"
// answer.evidence  → "Frame No. XJ-100A"   (verbatim span on the page, or nil)
// answer.page      → 2                      (0-indexed; nil for single-page docs)
```

Multi-page documents work the same way — pass `[VLMImage]`:

```swift
let extraction = try await DocumentQA.extract(on: pages, runner: runner, maxFieldsPerPage: 16)
let answer = try await DocumentQA.ask("保証期間は何年?", on: pages, runner: runner)
```

Stream the answer letter-by-letter for a live typewriter UI (no fake animation
— the recipe parses the partial JSON as the model generates):

```swift
let result = try await DocumentQA.ask(question, on: image, runner: runner) { partial in
    print(partial)   // "X" → "XJ" → "XJ-1" → … → "XJ-100A"
}
```

Optionally ground each extracted value back to a box on the photo using your
own OCR pass (Vision / Tesseract / …). The recipe stays OCR-engine-agnostic:

```swift
let observations: [OCRObservation] = …  // e.g. Vision: VNRecognizeTextRequest results
let boxes = DocumentQA.locate(fields: extraction.fields, in: observations)
// boxes[0] → CGRect(…)   (image-normalized, top-left). Absent when not found.
```

Matching normalizes full-width → half-width (`"ＸＪ-１００"` matches `"XJ-100"`),
folds case, collapses whitespace, and prefers the **tightest** containing
observation — the value's own box wins over a long line that happens to mention it.

### Describe & Point

The VLM writes a short caption of the image and names the concrete objects it
mentions; a separate on-device detector boxes each named object in caption
order. The split is deliberate: VLMs hallucinate coordinates, but they
describe well — so the recipe returns *language only* (a caption plus, for
each named object, the verbatim caption span and a short detector noun). You
hand the detector nouns to YOLOE, MobileSAM, or any open-vocab detector to
get the boxes.

```swift
let description = try await DescribeAndPoint.run(on: image, runner: runner, maxObjects: 8)
// description.caption → "A black dog playing fetch with a red ball on green grass."
// description.objects → [
//   DescribedObject(phrase: "black dog",  query: "dog",  range: …),
//   DescribedObject(phrase: "red ball",   query: "ball", range: …),
//   DescribedObject(phrase: "green grass", query: "grass", range: …),
// ]
```

`phrase` drives an in-caption highlight; `query` is what you feed the
detector. Objects are ordered by their position in the caption text, and
ones whose `phrase` cannot be located verbatim are dropped.

### Crowd Analytics

Apple's Vision detects every person in the image; the VLM answers a question
about each one. Counting people is a textbook VLM weak spot — Vision does
that part. Each person crop also gives the VLM far more effective resolution
than one full-image pass would.

```swift
let report = try await CrowdAnalytics.run(
    on: image, runner: runner,
    question: "Is this person wearing a hard hat?",
    maxPeople: 24
)
// report.totalPeople → 14
// report.people      → [
//   CrowdPerson(id: "person-0", summary: "Yes (hard hat)",     description: "…", box: CGRect(…)),
//   CrowdPerson(id: "person-1", summary: "No (cap, no helmet)", description: "…", box: CGRect(…)),
//   …
// ]
```

With no `question` it profiles each person (clothing, posture, what they
appear to be doing).

### Receipt

<img src="https://github.com/user-attachments/assets/4e78c448-39f9-484a-ad28-5aa379180b59" width="280" alt="Receipt demo" />

One typed call returns a fixed receipt schema you can sum, sort, and export.
Every field is optional — `nil` is more honest than a hallucinated value.

```swift
let receipt = try await Receipt.extract(on: image, runner: runner)
// receipt.merchant      → "Lawson"
// receipt.date          → "2026-06-01"      (YYYY-MM-DD when normalizable; raw otherwise)
// receipt.currency      → "JPY"             (ISO 4217 when recognizable)
// receipt.total         → 1280
// receipt.subtotal      → 1168
// receipt.tax           → 112
// receipt.paymentMethod → "Suica"
// receipt.category      → "convenience"
// receipt.items         → [ReceiptLineItem(name: "おにぎり 鮭", quantity: 2, amount: 200), …]

print(Receipt.csvRow(receipt))   // One CSV row per receipt
```

`Receipt.csv([receipt1, receipt2, …])` writes a full spreadsheet with header.
On-device — no FinanceKit dependency (Apple restricts that to banking apps),
which makes Receipt the building block for anyone shipping a personal-finance
app outside that bucket.

### Business Card

Read a card into a typed struct; the example app drops the result into a
`CNContactViewController` preview so the user confirms before saving to Apple
Contacts. Pure OCR misses logo-rendered company names, stylized titles, and
non-Latin scripts; the VLM reads what's actually printed.

```swift
let card = try await BusinessCard.extract(on: image, runner: runner)
// card.fullName, card.company, card.title, card.phones,
// card.emails, card.urls, card.address, card.socials, card.phoneticName (ふりがな)

let vcard = BusinessCard.vCard(card)   // standard 4.0 vCard string for sharing / saving
```

The recipe captures Japanese phonetic-name fields (`ふりがな`) so Contacts'
search-by-pronunciation works after import.

### Listing

Marketplace listing builder. The VLM reads multiple photos of one item and
writes a draft (title, description, features, condition, suggested price
range, tags, alt-text). The user can refine via a natural-language
instruction; the VLM keeps what works and changes only what was asked.

```swift
let draft = try await Listing.generate(
    on: [front, back, label],
    intent: "Mercari, casual tone, Japanese buyers",
    runner: runner
)
// draft.title       → "ナイキ エアジョーダン1 ロー OG 26.5cm"
// draft.description → "…"
// draft.features    → ["Box & laces included", "Worn once indoors", …]
// draft.condition   → "Like New"
// draft.suggestedPriceRange → "¥18,000 - 22,000"
// draft.tags        → ["nike", "air jordan", "sneakers", …]

let revised = try await Listing.refine(
    draft, on: photos, instruction: "Tighten to under 150 words and emphasize the box",
    runner: runner
)
```

Generation rather than extraction — the VLM is writing copy, not transcribing.

### Shelf Inventory

Tile the image, list products per tile, aggregate counts. Region-axis fan-out:
per-tile crops give the VLM more effective resolution, and splitting the count
avoids the "count many objects at once" failure mode.

```swift
let report = try await ShelfInventory.run(on: image, runner: runner, rows: 3, columns: 3) { done, total in
    print("tile \(done)/\(total)")
}
// report.totalCount → 42
// report.items      → [ShelfItemCount(name: "Coke", count: 8), …]
```

### Form Extraction

One typed call returns a value per requested field — the open-schema
counterpart to Receipt / BusinessCard. Use this when the schema is yours,
not a known document type.

```swift
let fields = [
    FormField("invoice_number"),
    FormField("total", description: "grand total with currency"),
    FormField("date"),
]
let values = try await FormExtraction.extract(fields: fields, from: image, runner: runner)
// ["invoice_number": "INV-2031", "total": "$1,240.00", "date": "2026-05-01"]
```

### Checklist

Task-axis fan-out: each requirement is judged in its own call against the
same image, so verdicts stay independent and each carries a reason. This is
the basis for the compliance (Genre ζ) recipes.

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

## Example app

`Examples/VLMKitDemo/` is a SwiftUI showcase of every recipe above plus one
LiDAR-driven demo that lives in the app rather than the library:

**AR Measure** — ARKit + LiDAR + Vision instance segmentation gives a 3D
bounding box (W / H / D / volume) of an object on the floor or table; the VLM
labels what's inside the box. Two different primitives, one combined answer:
"Wooden chair, 480 × 850 × 520 mm, 0.21 m³". Useful for moving estimates,
fit-checks, and storage planning.

Build with `xcodegen generate` from `Examples/VLMKitDemo/` (project.yml is
included; the `.xcodeproj` is generated and gitignored).

## CLI

A macOS command-line tool to try recipes and benchmark, with no app required:

```bash
swift run vlmkit-cli describe       photo.jpg
swift run vlmkit-cli describepoint  photo.jpg --max 8
swift run vlmkit-cli shelf          shelf.jpg --rows 3 --cols 3
swift run vlmkit-cli crowd          crowd.jpg --ask "Is this person wearing a hard hat?"
swift run vlmkit-cli form           invoice.jpg --fields "invoice_number,total,date"
swift run vlmkit-cli docqa          plate.jpg  --ask "What is the frame number?"
swift run vlmkit-cli checklist      site.jpg   --items "Workers wear hard hats; Fire exit is clear"
swift run vlmkit-cli bench          shelf.jpg  --runs 5 --model qwen3-4b
```

`describepoint` returns the **Describe & Point** recipe's JSON
(`{caption, objects:[{phrase, query}]}`) — the VLM-only half of the demo. Boxes
are produced by an on-device detector in the example app, not in the recipe.

`docqa` is the **Document QA** recipe: with no `--ask`, it auto-extracts every
labeled value off the page (`{fields:[{label,value}]}`); with `--ask`, it also
answers the question (`{answer, evidence}`).

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
Layer 2  Recipes          ShelfInventory · CrowdAnalytics · DescribeAndPoint
                          DocumentQA · Receipt · BusinessCard · Listing
                          FormExtraction · Checklist · …
Layer 1  Core framework   RegionExtractor · VLMRunner · Aggregator · FanoutPipeline
                          VLMBackend · ModelProfile · VLMCapabilities
```

| Primitive | Role |
| --- | --- |
| `RegionExtractor` | decide *where* to look — `FullImageExtractor`, `GridExtractor`, `VisionObjectExtractor`, `VisionPersonExtractor` |
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

- **Phase 1 ✓** Core + MLX backend + Genre α recipes
- **Phase 2** Saturate Genre α (remaining sub-recipes)
- **Phase 3** Genre β visual diff · `CoreMLBackend`
- **Phase 4** Genre γ video indexing (SQLite + embeddings + search)
- **Phase 5** Genre δ video narrative
- **Phase 6** Genre ε spatial AR (ARKit + LiDAR)
- **Phase 7** Genre ζ anomaly / compliance · `AppleFoundationBackend`

## License

MIT — see [LICENSE](LICENSE). Model weights carry their own licenses.
