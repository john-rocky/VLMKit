# VLMKit — on-device demos

A one-screen iOS showcase for VLMKit's structured fan-out recipes. Pick a demo,
give it a photo, and watch an Apple on-device framework pair with a local VLM to
turn pixels into structured, point-able results — entirely on-device.

Three demos ship behind a picker, on one shared shell (photo on top, structured
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

## Manual setup (without XcodeGen)

1. Create a new iOS App (SwiftUI, iOS 17) in Xcode.
2. **File ▸ Add Package Dependencies… ▸ Add Local…**, select this repository root.
3. Add the `Sources/*.swift` files to the target.
4. Set `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` in the
   target's Info settings.
5. Run on a real device.

The generated `ShelfScout.xcodeproj` is git-ignored — regenerate it any time with
`xcodegen generate`.
