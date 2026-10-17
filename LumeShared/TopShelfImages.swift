//
//  TopShelfImages.swift
//  LumeShared
//
//  What the Top Shelf's image renderers share — the extension's channel
//  tiles and the app's carousel art: downloading an image without decoding
//  it at full size, the cache folders finished images go in (the App Group's
//  Caches directory, the only place tvOS lets the extension write, and where
//  it reads the app's), and pruning what's no longer shown.
//

#if canImport(UIKit)
    import CryptoKit
    import ImageIO
    import UIKit

    nonisolated enum TopShelfImages {
        /// Roll a small number of workers forward instead of decoding every
        /// channel logo at once in the memory-constrained extension.
        static func boundedMap<Input: Sendable, Output: Sendable>(
            _ inputs: [Input], concurrency: Int = 3,
            transform: @escaping @Sendable (Input) async -> Output
        ) async -> [Output] {
            guard !Task.isCancelled else { return [] }
            return await withTaskGroup(of: Output.self) { group in
                var iterator = inputs.makeIterator()
                for _ in 0 ..< min(max(1, concurrency), inputs.count) {
                    if let input = iterator.next() { group.addTask { await transform(input) } }
                }
                var results: [Output] = []
                for await result in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    results.append(result)
                    if let input = iterator.next() { group.addTask { await transform(input) } }
                }
                return results
            }
        }

        /// A cache folder beside the snapshot, created if needed.
        static func directory(_ name: String) -> URL? {
            guard let directory = WidgetDataStore.snapshotURL?
                .deletingLastPathComponent()
                .appendingPathComponent(name, isDirectory: true) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        /// Downloads (http and https only) and decodes an image through an
        /// ImageIO thumbnail no larger than `maxPixelSize` — extensions run on
        /// a tight memory budget, so a huge image is never decoded at full size.
        static func download(_ url: URL, maxPixelSize: Int) async -> CGImage? {
            // Logo URLs are the provider's: only fetch over the network, never
            // a `file:` URL that would read a local file into a tile.
            guard let artwork = ArtworkRequest(url: url) else { return nil }
            var request = artwork.request
            // Downloads run in parallel and the Top Shelf waits for all of them,
            // so this bounds how long one slow host can hold it up.
            request.timeoutInterval = 4
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        }

        /// A file name keyed by everything an image shows, so a change renders
        /// anew.
        static func fileName(for key: String, extension pathExtension: String = "png") -> String {
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return "\(digest.prefix(32)).\(pathExtension)"
        }

        /// Writes a rendered image as PNG, returning its file URL.
        static func write(_ image: UIImage, to file: URL) -> URL? {
            save(image.pngData(), to: file)
        }

        /// Writes an opaque rendered image as JPEG — a fraction of the PNG's
        /// size for photographic art — returning its file URL.
        static func writeJPEG(_ image: UIImage, to file: URL) -> URL? {
            save(image.jpegData(compressionQuality: 0.85), to: file)
        }

        private static func save(_ data: Data?, to file: URL) -> URL? {
            guard let data, (try? data.write(to: file, options: .atomic)) != nil else { return nil }
            return file
        }

        /// Deletes every file in `directory` not named in `names`.
        static func prune(_ directory: URL, keeping names: Set<String>) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files where !names.contains(file) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
        }
    }
#endif
