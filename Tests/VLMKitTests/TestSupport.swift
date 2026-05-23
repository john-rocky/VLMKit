import CoreGraphics
import XCTest
@testable import VLMKit

/// A blank RGBA image for tests that only need a `VLMImage` of known size
/// (extractor geometry, cropping). No model or GPU involved.
func makeTestImage(width: Int = 16, height: Int = 16) -> VLMImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return VLMImage(cgImage: context.makeImage()!)
}

func makeRegionResult<Output>(_ output: Output) -> RegionResult<Output> {
    RegionResult(region: Region(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1)), output: output)
}
