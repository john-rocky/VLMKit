//
//  VLMDescriptionService.swift
//  ProductMeasure
//
//  After a measurement completes, runs VLMKit on the captured AR frame to
//  produce a short description of the measured object. Uses the process-wide
//  `SharedVLM` so we don't load a second ~3 GB copy of the model alongside the
//  one already loaded at app launch — which would jetsam the app on iOS.
//

import Foundation
import UIKit
import VLMKit

@MainActor
final class VLMDescriptionService {
    static let shared = VLMDescriptionService()
    private init() {}

    /// Returns a one-sentence description of the object in `image`, or nil if
    /// the model failed to load or the response was empty. Each `await` below
    /// is a suspension point, so MainActor is not held during the VLM call.
    func describe(_ image: UIImage) async -> String? {
        guard let vlmImage = VLMImage(uiImage: image) else {
            print("[VLMDescribe] VLMImage(uiImage:) returned nil")
            return nil
        }
        do {
            print("[VLMDescribe] awaiting SharedVLM.loadIfNeeded …")
            try await SharedVLM.loadIfNeeded()
            print("[VLMDescribe] loadIfNeeded OK")
        } catch {
            print("[VLMDescribe] loadIfNeeded threw: \(error)")
            return nil
        }
        let prompt = """
        Describe this object in one short sentence (max 25 words). \
        Include what it is, distinctive visible features (color, material, \
        markings), and typical use if recognizable. Skip background and people.
        """
        do {
            print("[VLMDescribe] calling backend.generate …")
            let result = try await SharedVLM.backend.generate(
                prompt: prompt,
                system: nil,
                images: [vlmImage],
                options: GenerationOptions(maxTokens: 90, temperature: 0.2)
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[VLMDescribe] backend.generate returned (len=\(text.count)): \(text.prefix(120))")
            return text.isEmpty ? nil : text
        } catch {
            print("[VLMDescribe] backend.generate threw: \(error)")
            return nil
        }
    }
}
