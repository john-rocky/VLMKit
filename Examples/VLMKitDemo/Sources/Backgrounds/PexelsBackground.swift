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
        let pool = try await searchURLs(query: style, canvasSize: canvasSize)
        if pool.isEmpty { throw PexelsError.noResults }
        let urls = Self.pickFromPool(pool, count: count)
        return try await downloadImages(urls)
    }

    // MARK: - Search

    /// Pexels Photos API: GET /v1/search?query=...&per_page=15
    /// We DON'T constrain `orientation`. Pexels has very few square photos,
    /// and even for a square canvas the cover-fill in `BackgroundCompositor`
    /// handles landscape/portrait sources fine — restricting orientation
    /// shrinks the result pool to a handful of low-variety square close-ups.
    ///
    /// `per_page` is much larger than needed so the caller can pick past
    /// the most-relevant (and often blandest — clean white, "minimalist"
    /// SEO-bait) top results into the more visually-interesting middle
    /// of the result set. See `pickFromPool`.
    private func searchURLs(
        query: String, canvasSize: CGSize
    ) async throws -> [URL] {
        var components = URLComponents(string: "https://api.pexels.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: String(Self.poolSize)),
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

    /// How many photos to ask Pexels for per query. Empirically, the top
    /// 1–2 results for scene queries are over-stylized white-wall shots;
    /// the middle of a 15-photo page tends to have more characterful
    /// environment photos.
    private static let poolSize = 15
    /// Skip the first N results. The blandest "minimalist" / clean-white
    /// shots dominate the top of Pexels' relevance ranking for scene
    /// queries; positions 3+ are usually richer.
    private static let skipTop = 3

    /// Pick `count` photos from `pool`, starting at `skipTop` so we land
    /// past the blandest top hits. Falls back to the start of the pool
    /// when there aren't enough photos to skip.
    static func pickFromPool(_ pool: [URL], count: Int) -> [URL] {
        guard !pool.isEmpty else { return [] }
        let n = max(count, 1)
        let start = pool.count > skipTop + n ? skipTop : 0
        return Array(pool.dropFirst(start).prefix(n))
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
