import SwiftUI

/// ShelfScout — a one-screen showcase for VLMKit's α1 Shelf Inventory recipe.
/// Point the camera at a retail shelf; the recipe tiles the image and fans out
/// VLM calls per tile, then aggregates a product count — all on-device.
@main
struct ShelfScoutApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
