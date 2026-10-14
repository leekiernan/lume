//
//  TopShelfImages.swift
//  LumeTopShelf
//
//  What the extension's renderers share: downloading an image without
//  decoding it at full size, the cache folders they write finished images to
//  (the shared Caches directory, the only place tvOS lets an extension write),
//  and pruning what's no longer shown.
//

import CryptoKit
import ImageIO
import UIKit

enum TopShelfImages {
    /// A cache folder beside the snapshot, created if needed.
    static func directory(_ name: String) -> URL? {
        guard let directory = WidgetDataStore.snapshotURL?
            .deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Downloads and decodes an image through an ImageIO thumbnail no larger
    /// than `maxPixelSize` — extensions run on a tight memory budget, so a
    /// huge image is never decoded at full size.
    static func download(_ url: URL, maxPixelSize: Int) async -> CGImage? {
        var request = URLRequest(url: url)
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
    static func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(digest.prefix(32)).png"
    }

    /// Writes a rendered image, returning its file URL.
    static func write(_ image: UIImage, to file: URL) -> URL? {
        guard let data = image.pngData(), (try? data.write(to: file, options: .atomic)) != nil else { return nil }
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
