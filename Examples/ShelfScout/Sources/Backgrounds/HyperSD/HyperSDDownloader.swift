import Foundation
import ZIPFoundation

/// Downloads the four HyperSD release zips from
/// `github.com/john-rocky/CoreML-Models/releases/tag/hypersd-v1` into
/// `Documents/HyperSDModels/`, extracts them, and renames the unzipped
/// folders to the canonical names the pipeline expects.
///
/// Each asset is downloaded to a tmp file, unzipped into a tmp staging
/// directory, then atomically moved into the destination — so the on-disk
/// state only ever contains complete `.mlpackage` bundles. A half-finished
/// download leaves nothing behind in `HyperSDModels/`.
///
/// Progress is reported as an `Update` with the current asset's index/name
/// and the overall fraction (0...1) of total bytes done.
@available(iOS 16.2, *)
final class HyperSDDownloader: @unchecked Sendable {

    struct Asset: Sendable {
        let zipURL: URL
        /// Canonical name of the extracted `.mlpackage` folder in
        /// `Documents/HyperSDModels/` — matches `HyperSDPipeline.Resources`.
        let targetName: String
        /// Compressed size from the release manifest; used to weight each
        /// asset's contribution to the combined progress fraction.
        let estimatedSize: Int64
    }

    struct Update: Sendable, Equatable {
        let assetIndex: Int
        let assetCount: Int
        let assetName: String
        /// 0...1 across all assets, weighted by `estimatedSize`.
        let fraction: Double
    }

    static let assets: [Asset] = [
        Asset(
            zipURL: URL(string: "https://github.com/john-rocky/CoreML-Models/releases/download/hypersd-v1/HyperSDTextEncoder.mlpackage.zip")!,
            targetName: HyperSDPipeline.Resources.textEncoderName,
            estimatedSize: 226_397_794
        ),
        Asset(
            zipURL: URL(string: "https://github.com/john-rocky/CoreML-Models/releases/download/hypersd-v1/HyperSDUnetChunk1.mlpackage.zip")!,
            targetName: HyperSDPipeline.Resources.unetChunk1Name,
            estimatedSize: 324_819_653
        ),
        Asset(
            zipURL: URL(string: "https://github.com/john-rocky/CoreML-Models/releases/download/hypersd-v1/HyperSDUnetChunk2.mlpackage.zip")!,
            targetName: HyperSDPipeline.Resources.unetChunk2Name,
            estimatedSize: 304_530_429
        ),
        Asset(
            zipURL: URL(string: "https://github.com/john-rocky/CoreML-Models/releases/download/hypersd-v1/HyperSDVAEDecoder.mlpackage.zip")!,
            targetName: HyperSDPipeline.Resources.decoderName,
            estimatedSize: 91_282_754
        ),
    ]

    static var totalBytes: Int64 {
        assets.reduce(0) { $0 + $1.estimatedSize }
    }

    /// Download every asset not already present in `destination`. Already-
    /// present folders count as 100% done so a resumed run after a partial
    /// failure only re-fetches the missing ones.
    func downloadIfNeeded(
        into destination: URL,
        onProgress: @escaping @Sendable (Update) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var doneBytes: Int64 = 0
        var pending: [(index: Int, asset: Asset)] = []
        for (index, asset) in Self.assets.enumerated() {
            let target = destination.appendingPathComponent(asset.targetName)
            if fm.fileExists(atPath: target.path) {
                doneBytes += asset.estimatedSize
            } else {
                pending.append((index, asset))
            }
        }
        let total = Self.totalBytes
        // Emit an initial update so the UI can immediately show the right
        // starting position (important when resuming a partial download).
        if let first = pending.first {
            onProgress(Update(
                assetIndex: first.index,
                assetCount: Self.assets.count,
                assetName: first.asset.targetName,
                fraction: Double(doneBytes) / Double(total)
            ))
        }

        for (index, asset) in pending {
            try await downloadAndExtract(
                asset: asset,
                assetIndex: index,
                destination: destination,
                accumulatedBytes: doneBytes,
                totalBytes: total,
                onProgress: onProgress
            )
            doneBytes += asset.estimatedSize
            onProgress(Update(
                assetIndex: index,
                assetCount: Self.assets.count,
                assetName: asset.targetName,
                fraction: Double(doneBytes) / Double(total)
            ))
        }
    }

    // MARK: - Per-asset

    private func downloadAndExtract(
        asset: Asset,
        assetIndex: Int,
        destination: URL,
        accumulatedBytes: Int64,
        totalBytes: Int64,
        onProgress: @escaping @Sendable (Update) -> Void
    ) async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpZip = tmpDir.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: tmpZip) }

        try await streamDownload(
            from: asset.zipURL,
            into: tmpZip,
            asset: asset,
            assetIndex: assetIndex,
            accumulatedBytes: accumulatedBytes,
            totalBytes: totalBytes,
            onProgress: onProgress
        )

        // Extract into a tmp staging dir, then move the resulting `.mlpackage`
        // into destination under its canonical name. Doing the unzip into a
        // staging dir keeps a failed extraction from leaving a partial
        // mlpackage that the pipeline's "are models present" probe would
        // mistakenly accept.
        let staging = tmpDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.unzipItem(at: tmpZip, to: staging)
        } catch {
            throw HyperSDError.unzipFailed(asset.targetName)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil
        )) ?? []
        guard let extracted = contents.first(where: { $0.pathExtension == "mlpackage" })
            ?? contents.first
        else {
            throw HyperSDError.unzipFailed(asset.targetName)
        }
        let final = destination.appendingPathComponent(asset.targetName)
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: extracted, to: final)
    }

    private func streamDownload(
        from url: URL,
        into target: URL,
        asset: Asset,
        assetIndex: Int,
        accumulatedBytes: Int64,
        totalBytes: Int64,
        onProgress: @escaping @Sendable (Update) -> Void
    ) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw HyperSDError.downloadFailed(asset.targetName)
        }
        let expected: Int64 = response.expectedContentLength > 0
            ? response.expectedContentLength
            : asset.estimatedSize

        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        let reportEvery: Int64 = 1024 * 1024  // throttle UI updates to ~1MB
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var written: Int64 = 0
        var nextReport: Int64 = reportEvery

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if written >= nextReport {
                    let assetFraction = Double(written) / Double(expected)
                    let overall = (Double(accumulatedBytes)
                        + Double(asset.estimatedSize) * assetFraction)
                        / Double(totalBytes)
                    onProgress(Update(
                        assetIndex: assetIndex,
                        assetCount: Self.assets.count,
                        assetName: asset.targetName,
                        fraction: min(overall, 0.999)
                    ))
                    nextReport += reportEvery
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
    }
}
