# ShelfScout

A one-screen iOS showcase for VLMKit's **α1 Shelf Inventory** recipe. Point the
camera at a retail shelf (or pick a photo); the recipe tiles the image, fans out
one VLM call per tile, and aggregates a product count — entirely on-device.

## Requirements

- Xcode 16+
- A **real iOS device** (A-series / M-series). MLX uses the Metal GPU and does
  **not** run on the iOS Simulator.
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
> `Sources/ScanViewModel.swift` (~1 GB).

## Manual setup (without XcodeGen)

1. Create a new iOS App (SwiftUI, iOS 17) in Xcode.
2. **File ▸ Add Package Dependencies… ▸ Add Local…**, select this repository root.
3. Add the `Sources/*.swift` files to the target.
4. Set `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` in the
   target's Info settings.
5. Run on a real device.

The generated `ShelfScout.xcodeproj` is git-ignored — regenerate it any time with
`xcodegen generate`.
