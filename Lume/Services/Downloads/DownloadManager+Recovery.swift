import Foundation
import OSLog
import SwiftData

extension DownloadManager {
    /// Keeps downloaded media out of the user's iCloud / Finder backup.
    ///
    /// `Documents` is backed up by default, so a handful of downloaded films
    /// silently added gigabytes to the user's backup — against Apple's Data
    /// Storage Guidelines, which put content the app can fetch again but the
    /// user expects offline in exactly this "do not back up" bucket. Apps have
    /// been rejected over far smaller amounts.
    ///
    /// Set on the *directory*, which covers everything already inside it and
    /// everything added later, so individual downloads need no bookkeeping.
    ///
    /// Deliberately not `Library/Caches`, the other usual answer: the system may
    /// purge Caches under storage pressure, which would delete the film someone
    /// downloaded for a flight. This attribute gives the semantics actually
    /// wanted — not backed up, and never purged.
    ///
    /// Idempotent, and called on every launch rather than only at creation, so
    /// installs that already have a downloads directory are corrected too.
    nonisolated static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            // Not fatal — downloads still work, they just keep getting backed
            // up. Logged because the symptom (a bloated backup) is otherwise
            // invisible from inside the app.
            Logger.downloads.error("Failed to exclude downloads from backup: \(error.localizedDescription)")
        }
    }

    nonisolated static func persistStatus(
        id: String,
        status: DownloadStatus?,
        localURL: String?,
        container: ModelContainer
    ) async {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            var movieDesc = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            movieDesc.fetchLimit = 1
            if let movie = try context.fetch(movieDesc).first {
                movie.downloadStatus = status
                movie.localFileURL = localURL
                movie.downloadedAt = status == .completed ? Date() : nil
                try context.save()
                return
            }
            var epDesc = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            epDesc.fetchLimit = 1
            if let episode = try context.fetch(epDesc).first {
                episode.downloadStatus = status
                episode.localFileURL = localURL
                episode.downloadedAt = status == .completed ? Date() : nil
                try context.save()
            }
        } catch {
            Logger.downloads.error("Failed to persist download status for \(id): \(error)")
        }
    }

    nonisolated static func isDownloadFile(_ url: URL, for sanitizedID: String) -> Bool {
        DownloadFileIdentity.matches(url, stem: sanitizedID)
    }

    /// Settles catalog items still marked `pending`/`downloading` that the
    /// restored session knows nothing about.
    ///
    /// Two things strand them: the user force-quitting Lume (which makes the
    /// system cancel its background transfers outright), and the app being
    /// suspended after the file was moved but before the SwiftData write landed.
    /// Disk is the authority for telling those apart — if the file is there the
    /// download did finish, whatever the stored status says.
    nonisolated static func recoverInterruptedDownloads(
        liveIDs: Set<String>,
        directory: URL,
        container: ModelContainer
    ) async {
        let pending = DownloadStatus.pending.rawValue
        let downloading = DownloadStatus.downloading.rawValue
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        // One directory pass, not a full file scan per interrupted catalogue row.
        var filesByStem: [String: [URL]] = [:]
        for file in files {
            for stem in DownloadFileIdentity.stems(for: file) {
                filesByStem[stem, default: []].append(file)
            }
        }

        /// The finished file for `id`, if one is already on disk.
        func downloadedFile(for id: String) -> URL? {
            let sanitized = sanitize(id)
            return filesByStem[sanitized]?.first { DownloadValidator.isUsableFile(at: $0) }
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let movies = try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate {
                $0.downloadStatusRaw == pending || $0.downloadStatusRaw == downloading
            }))
            let episodes = try context.fetch(FetchDescriptor<Episode>(predicate: #Predicate {
                $0.downloadStatusRaw == pending || $0.downloadStatusRaw == downloading
            }))
            var recovered = 0
            for movie in movies where !liveIDs.contains(movie.id) {
                let file = downloadedFile(for: movie.id)
                movie.downloadStatus = file == nil ? .failed : .completed
                movie.localFileURL = file?.lastPathComponent
                movie.downloadedAt = file == nil ? nil : Date()
                recovered += 1
            }
            for episode in episodes where !liveIDs.contains(episode.id) {
                let file = downloadedFile(for: episode.id)
                episode.downloadStatus = file == nil ? .failed : .completed
                episode.localFileURL = file?.lastPathComponent
                episode.downloadedAt = file == nil ? nil : Date()
                recovered += 1
            }
            guard recovered > 0 else { return }
            try context.save()
            Logger.downloads.info("Recovered \(recovered) interrupted download(s)")
        } catch {
            Logger.downloads.error("Failed to recover interrupted downloads: \(error)")
        }
    }
}
