# VLMKit — on-device demos

A one-screen iOS showcase for VLMKit's structured fan-out recipes. Pick a demo,
give it a photo, and watch an Apple on-device framework pair with a local VLM to
turn pixels into structured, point-able results — entirely on-device.

Four demos ship behind a picker, on one shared shell (photo on top, structured
result below, with two-way result ↔ box highlighting):

- **α1 Shelf Inventory** — tiles the image (grid fan-out), runs one VLM call per
  tile, and aggregates a product count with per-product boxes.
- **α2 Crowd Analytics** — **Vision** (`VNDetectHumanRectanglesRequest`) detects
  each person, then one VLM call profiles each one with a detailed description.
  Vision says *where* the people are; the VLM says *who* they are. This Apple-
  framework × VLM pairing is VLMKit's core idea.
- **P5 ROI Zoom** — tap any object and **MobileSAM**
  ([SAMKit](https://github.com/john-rocky/SamKit)) segments it on-device; the VLM
  then reads a high-resolution crop of just that region, surfacing fine detail
  (small text, marks, defects) the whole-image pass downscales away. SAM says
  *where* the detail is; the VLM reads it.
- **Describe & Point** — the VLM writes a short caption and names the concrete
  objects in it; **YOLOE** (open-vocabulary text-grounded detection +
  segmentation, from [CoreML-Models](https://github.com/john-rocky/CoreML-Models))
  boxes each one. The caption's words and the photo's boxes advance together
  under the auto-tour, so each spoken object is grounded in pixels. The VLM
  names *what*; YOLOE finds *where*.

> The app is named **VLMKit** on the home screen. Its Xcode project still lives in
> `Examples/ShelfScout/` and the bundle id stays `com.vlmkit.example.shelfscout`
> (so a model sideloaded into the existing app container is preserved).

## Requirements

- Xcode 16+
- A **real iOS device** (A-series / M-series). MLX uses the Metal GPU and does
  **not** run on the iOS Simulator. Vision detection is also unreliable on the
  Simulator.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Run

```sh
cd Examples/ShelfScout
xcodegen generate
open ShelfScout.xcodeproj
```

In Xcode: select your team under **Signing & Capabilities**, choose your
connected device, and Run. On first launch the app downloads the default model
(Qwen3-VL-4B, ~3 GB) from Hugging Face and caches it.

> Tip: for a smaller, faster first test, change `.qwen3VL4B` to `.smolVLM2` in
> `Sources/DemoViewModel.swift` (~1 GB).

## MobileSAM models (ROI Zoom demo)

The **ROI Zoom** demo segments tapped objects with MobileSAM (via SAMKit). Its
Core ML models (~23 MB) are **not** committed — download them once and drop them
into `Sources/Models/` so Xcode bundles them:

```sh
cd Examples/ShelfScout/Sources/Models
gh release download v1.0.0 --repo john-rocky/SamKit --pattern MobileSAM.zip
unzip MobileSAM.zip && rm MobileSAM.zip
```

This yields `mobile_sam_encoder.mlpackage`, `mobile_sam_decoder.mlpackage`, and
`mobile_sam_prompt_encoder_weights.json` (all git-ignored). Re-run `xcodegen
generate` so the project picks them up. Without them the other demos still run;
ROI Zoom shows a "models not found" hint.

## YOLOE models (Describe & Point demo)

The **Describe & Point** demo uses YOLOE for open-vocabulary text-grounded
detection (the "point" half — the VLM names objects, YOLOE localises them). Its
Core ML models (~148 MB) are **not** committed — download them once from the
`yoloe-v1` release of
[`john-rocky/CoreML-Models`](https://github.com/john-rocky/CoreML-Models) and
drop them into `Sources/Models/`:

```sh
cd Examples/ShelfScout/Sources/Models
gh release download yoloe-v1 --repo john-rocky/CoreML-Models \
  -p 'yoloe_detector_s.mlpackage.zip' \
  -p 'reprta_s.mlpackage.zip' \
  -p 'mobileclip_blt_text.mlpackage.zip' \
  -p 'clip_vocab.json.zip'
for z in *.zip; do unzip -q "$z" && rm "$z"; done
find . -name '._*' -delete                    # tidy macOS resource forks
mv yoloe_detector_s.mlpackage yoloe_detector.mlpackage
mv reprta_s.mlpackage reprta.mlpackage
```

This yields `yoloe_detector.mlpackage` (~20 MB), `reprta.mlpackage` (~6 MB),
`mobileclip_blt_text.mlpackage` (~121 MB), and `clip_vocab.json` (1.6 MB) — all
git-ignored. Re-run `xcodegen generate` so Xcode bundles them (`.mlpackage` →
`.mlmodelc`). Without them, the other demos still run; Describe & Point produces
a caption but no boxes (the provider logs `YOLOE models failed to load`).

The **S** detector is the default. To use the higher-accuracy **L** variant,
swap `yoloe_detector_s` → `yoloe_detector_l` and `reprta_s` → `reprta_l` in the
download step above — Swift needs no changes (the 512-dim embedding is shared
across S/L).

## Sideloading the model via USB (debug)

To avoid re-downloading the model on every clean install while debugging, push
it onto the device once. If `Documents/Model/config.json` is present, the app
loads the model from there and skips the Hugging Face download entirely.

1. On your Mac, download the full model repo into a folder named `Model`:
   ```sh
   pip install -U "huggingface_hub[hf_xet]"
   hf download lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit --local-dir Model
   ```
2. Connect the device via USB, open it in Finder, and select the **Files** tab.
   Drag the `Model` folder onto the **VLMKit** app.
3. Relaunch the app — it now loads the local model (no download).

The folder must be named `Model` and hold the full repo snapshot (`config.json`,
`*.safetensors`, and the tokenizer files). Delete it to return to the download
path. File sharing is enabled via `UIFileSharingEnabled` in `project.yml`.

## Pexels API key (optional, Listing → Background Studio)

The Listing demo's Background Studio offers three background sources: a
programmatic Solid/Gradient renderer (always on), Pexels stock photos, and
on-device Diffusion (see next section). The Pexels tab is hidden unless you've
added your key:

1. Sign up at [pexels.com/api](https://www.pexels.com/api/) (free, 200 req/h).
2. Open `Examples/ShelfScout/Sources/Backgrounds/PexelsAPIKey.swift` and set
   `static let key = "your-key-here"`.
3. Rebuild — the Pexels tab now appears in the Background Studio.

`PexelsAPIKey.swift` is gitignored, so your key stays local.

## HyperSD models (Listing → Background Studio → AI Diffusion)

The Background Studio's **AI Diffusion** mode generates a fresh background
fully on-device using HyperSD (1-step distilled Stable Diffusion 1.5, ~947 MB
in 6-bit palettized Core ML). iPhone 15+ (≥ 6 GB RAM) is required.

No setup — the four `.mlpackage` zips are fetched from the
[`john-rocky/CoreML-Models` `hypersd-v1` release](https://github.com/john-rocky/CoreML-Models/releases/tag/hypersd-v1)
the first time the user picks the **AI Diffusion** tab, extracted into
`Documents/HyperSDModels/`, and reused on every subsequent run. Progress
bar in the sheet shows which asset (1 of 4) and overall percent. The BPE
tokenizer (`vocab.json` + `merges.txt`) is bundled in the app at build
time because it's tiny and stable across SD 1.5 builds.

The pipeline drives Apple's `apple/ml-stable-diffusion` text encoder and VAE
decoder, plus a hand-rolled 1-step TCD scheduler and a thin Unet driver — see
`Sources/Backgrounds/HyperSD/`.

When the user picks AI Diffusion in the studio, the VLM is unloaded so the
~2 GB of HyperSD weights have room to run; the next VLM call after the sheet
closes pays a cold-load (~30 s).

## Manual setup (without XcodeGen)

1. Create a new iOS App (SwiftUI, iOS 17) in Xcode.
2. **File ▸ Add Package Dependencies… ▸ Add Local…**, select this repository root.
3. Add the `Sources/*.swift` files to the target.
4. Set `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` in the
   target's Info settings.
5. Run on a real device.

The generated `ShelfScout.xcodeproj` is git-ignored — regenerate it any time with
`xcodegen generate`.
