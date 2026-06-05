import Foundation
import UIKit

/// Pexels-backed background generator. Searches the Pexels Photos API for
/// stock images matching the VLM's style hint, picks the top results, and
/// returns them as `UIImage`. The free tier (200/h, 20k/mo) is plenty for
/// interactive use; the orchestrator limits to `count` requests per call.
///
/// Disabled unless `PexelsAPIKey.key` is non-empty — `BackgroundMode.pexels`
/// hides the tab when that's the case.
struct PexelsBackground: BackgroundGenerator {

    enum PexelsError: Error, LocalizedError {
        case missingKey
        case requestFailed(status: Int)
        case decodingFailed
        case noResults

        var errorDescription: String? {
            switch self {
            case .missingKey: "Pexels API key not set."
            case .requestFailed(let status): "Pexels API returned HTTP \(status)."
            case .decodingFailed: "Could not parse Pexels response."
            case .noResults: "No matching photos on Pexels."
            }
        }
    }

    func generate(
        style: String,
        count: Int,
        canvasSize: CGSize
    ) async throws -> [UIImage] {
        guard PexelsAPIKey.isPresent else { throw PexelsError.missingKey }
        let urls = try await searchURLs(
            query: style, count: count, canvasSize: canvasSize
        )
        if urls.isEmpty { throw PexelsError.noResults }
        return try await downloadImages(urls)
    }

    // MARK: - Search

    /// Pexels Photos API: GET /v1/search?query=...&per_page=N&orientation=...
    /// Picks `landscape`/`portrait`/`square` to roughly match the canvas — the
    /// compositor does a cover-fill so an off-aspect background still works,
    /// but matching the orientation gives a tighter cropping margin.
    private func searchURLs(
        query: String, count: Int, canvasSize: CGSize
    ) async throws -> [URL] {
        var components = URLComponents(string: "https://api.pexels.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: String(max(count, 1))),
            URLQueryItem(name: "orientation", value: orientation(for: canvasSize)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(PexelsAPIKey.key, forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PexelsError.requestFailed(status: http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            throw PexelsError.decodingFailed
        }
        return decoded.photos.compactMap { URL(string: $0.src.large2x ?? $0.src.large ?? $0.src.original) }
    }

    private func orientation(for canvas: CGSize) -> String {
        if canvas.width > canvas.height * 1.05 { return "landscape" }
        if canvas.height > canvas.width * 1.05 { return "portrait" }
        return "square"
    }

    // MARK: - Download

    private func downloadImages(_ urls: [URL]) async throws -> [UIImage] {
        await withTaskGroup(of: (Int, UIImage?).self, returning: [UIImage].self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { (index, await downloadImage(url)) }
            }
            var byIndex: [Int: UIImage] = [:]
            for await (i, maybe) in group {
                if let image = maybe { byIndex[i] = image }
            }
            return (0..<urls.count).compactMap { byIndex[$0] }
        }
    }

    private func downloadImage(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return UIImage(data: data)
    }

    // MARK: - Pexels API shape

    private struct SearchResponse: Decodable {
        let photos: [Photo]

        struct Photo: Decodable {
            let src: Src

            struct Src: Decodable {
                let original: String
                let large: String?
                let large2x: String?
            }
        }
    }
}
