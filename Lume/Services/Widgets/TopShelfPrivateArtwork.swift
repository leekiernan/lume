#if canImport(UIKit)
    import UIKit

    /// Materialises authenticated artwork in the app. The extension gets an
    /// image file, never a provider credential or a reusable authenticated URL.
    nonisolated enum TopShelfPrivateArtwork {
        static var defaultDirectory: URL? {
            TopShelfImages.directory("TopShelfPrivateArtwork")
        }

        typealias Loader = @Sendable (URL, Int) async -> CGImage?

        private struct Work {
            let url: URL
            let file: URL
        }

        static func applyCached(to snapshot: inout WidgetSnapshot, directory: URL? = defaultDirectory) {
            for section in snapshot.sections.indices {
                for index in snapshot.sections[section].items.indices {
                    let item = snapshot.sections[section].items[index]
                    snapshot.sections[section].items[index].imageURL = exported(item.imageURL, owner: item.id, directory: directory)
                    snapshot.sections[section].items[index].backdropURL = exported(item.backdropURL, owner: item.id, directory: directory)
                    snapshot.sections[section].items[index].logoURL = exported(item.logoURL, owner: item.id, directory: directory)
                }
            }
        }

        /// The first snapshot can publish using cached files alone. Missing
        /// files arrive in a second publication, under the same ownership gate.
        static func renderMissing(
            in snapshot: inout WidgetSnapshot, source: WidgetSnapshot,
            directory: URL? = defaultDirectory,
            load: @escaping Loader = { await TopShelfImages.download($0, maxPixelSize: $1) }
        ) async -> Bool {
            guard let directory else { return false }
            var pending: [URL: Work] = [:]
            for item in source.sections.flatMap(\.items) {
                for url in [item.imageURL, item.backdropURL, item.logoURL].compactMap(\.self) where ArtworkRequest.carriesCredentials(url) {
                    guard let file = file(for: url, owner: item.id, directory: directory), !FileManager.default.fileExists(atPath: file.path) else { continue }
                    pending[file] = Work(url: url, file: file)
                }
            }
            let rendered = await TopShelfImages.boundedMap(Array(pending.values)) { work -> URL? in
                guard !Task.isCancelled, let image = await load(work.url, 1920), !Task.isCancelled else { return nil }
                return TopShelfImages.write(UIImage(cgImage: image), to: work.file)
            }
            guard !Task.isCancelled, rendered.contains(where: { $0 != nil }) else { return false }
            var updated = source
            applyCached(to: &updated, directory: directory)
            for section in snapshot.sections.indices {
                for index in snapshot.sections[section].items.indices {
                    snapshot.sections[section].items[index].imageURL = updated.sections[section].items[index].imageURL
                    snapshot.sections[section].items[index].backdropURL = updated.sections[section].items[index].backdropURL
                    snapshot.sections[section].items[index].logoURL = updated.sections[section].items[index].logoURL
                }
            }
            return true
        }

        static func prune(keeping snapshot: WidgetSnapshot, directory: URL? = defaultDirectory) {
            guard let directory else { return }
            let urls = snapshot.sections.flatMap(\.items).flatMap { [$0.imageURL, $0.backdropURL, $0.logoURL].compactMap(\.self) }
            let names = urls.filter { $0.isFileURL && $0.deletingLastPathComponent() == directory }.map(\.lastPathComponent)
            TopShelfImages.prune(directory, keeping: Set(names))
        }

        private static func exported(_ url: URL?, owner: String, directory: URL?) -> URL? {
            guard let url, ArtworkRequest.carriesCredentials(url) else { return url }
            guard let directory, let file = file(for: url, owner: owner, directory: directory),
                  FileManager.default.fileExists(atPath: file.path) else { return nil }
            return file
        }

        private static func file(for url: URL, owner: String, directory: URL) -> URL? {
            // A playlist UUID alone does not identify its current account: its
            // credentials can be edited in place. Without a stable account ID
            // in the snapshot, retain the legacy credential fingerprint.
            guard let request = ArtworkRequest(url: url) else { return nil }
            let key = String(owner.prefix(36)) + "|" + request.cacheIdentity
            return directory.appendingPathComponent(TopShelfImages.fileName(for: key))
        }
    }
#endif
