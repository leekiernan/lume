import Foundation
import os
import OSLog
import SwiftData

// MARK: - DownloadManager

/// Central download manager. Serialises file downloads, persists completion
/// state into SwiftData, and exposes live progress to the UI.
///
/// Not available on tvOS — the download feature targets iOS and macOS only.
@MainActor
@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    // MARK: - Settings keys

    static let maxConcurrentKey = "downloads.maxConcurrent"
    static let autoDeleteKey = "downloads.autoDeleteAfterWatching"

    // MARK: - Public observable state

    /// Actively downloading items, keyed by content id.
    private(set) var activeDownloads: [String: ActiveDownload] = [:]
    /// Content ids that are queued but not yet started.
    private(set) var pendingIDs: Set<String> = []

    // MARK: - Private

    var modelContainer: ModelContainer?

    /// Per-task time of the last published progress update. `didWriteData`
    /// fires for every received chunk (often 100+ times per second); publishing
    /// each one into the observable `activeDownloads` re-rendered every
    /// observing view per chunk and saturated the main thread — visibly
    /// delaying unrelated interactions such as opening a context menu. Gates
    /// updates to one per task per 250 ms.
    private nonisolated let progressPublishGate = OSAllocatedUnfairLock<[Int: Date]>(initialState: [:])
    /// Do not release the background wake budget before completion alerts have
    /// reached the notification center. Enter before the delegate returns.
    private nonisolated let completionDeliveryGroup = DispatchGroup()

    private var session: URLSession!
    private var taskMap: [Int: String] = [:]
    private var idToTask: [String: URLSessionDownloadTask] = [:]
    private var idToFilename: [String: String] = [:]
    private var pendingQueue: [PendingDownload] = []
    private nonisolated let lifecycle = OSAllocatedUnfairLock(initialState: DownloadLifecycle())
    private var statusWrite: Task<Void, Never>?

    /// Handed over by `UIApplicationDelegate` when the app is relaunched to
    /// receive background session events. Must be called once the session has
    /// finished delivering them, or the system considers the relaunch unfinished.
    private var backgroundCompletionHandler: (() -> Void)?

    // MARK: - Init

    /// Identifier of the shared background session. Stable across launches —
    /// it is how the app reconnects to transfers `nsurlsessiond` is still running.
    private static let sessionIdentifier = "bilipp.Lume.downloads"

    override private init() {
        super.init()
        // A *background* configuration, not `.default`: a default session is
        // owned by the app process, so the system suspends it along with the app
        // and downloads stall the moment the user leaves Lume. A background
        // session hands the transfer to `nsurlsessiond`, which keeps running
        // while the app is suspended or terminated.
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Relaunch the app in the background to deliver completion events, so a
        // download that finishes while Lume is not running still gets its file
        // moved into place and its status persisted.
        config.sessionSendsLaunchEvents = true
        // These are user-initiated: the person tapped Download and expects it to
        // start now, not whenever the system next decides conditions are ideal.
        // (The default flips to `true` for sessions created while in the
        // background, so it has to be set explicitly rather than left alone.)
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 0
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        ensureDownloadsDirectory()
    }

    // MARK: - Configuration

    /// Owned transport for deterministic delegate/persistence tests. The shared
    /// instance above retains its stable system background-session identifier.
    init(sessionConfiguration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
    }

    /// Release an owned non-background transport and its retained delegate.
    func invalidateSession() {
        precondition(session.configuration.identifier == nil, "The shared background session must remain connected")
        session.invalidateAndCancel()
    }

    func configure(container: ModelContainer) {
        modelContainer = container
    }

    /// Re-adopts whatever the background session is still transferring, then
    /// reconciles the catalog against it. Call once per launch, after
    /// `configure(container:)`.
    ///
    /// The session outlives the process, so after a relaunch `nsurlsessiond`
    /// still holds the tasks while every map here is empty. Each task carries
    /// its own `DownloadTaskInfo`, which is enough to rebuild them.
    func restoreBackgroundSession() async {
        let tasks = Task { await session.allTasks }
        // Reserve the persistence lane before awaiting URLSession. New enqueues
        // and completion callbacks must land after recovery, not race against it.
        if let container = modelContainer {
            let previous = statusWrite
            let directory = downloadsDirectory
            statusWrite = Task.detached {
                await previous?.value
                let liveIDs = await Set(tasks.value.compactMap { DownloadTaskInfo(taskDescription: $0.taskDescription)?.id })
                await Self.recoverInterruptedDownloads(liveIDs: liveIDs, directory: directory, container: container)
            }
        }
        var liveIDs: Set<String> = []
        for task in await tasks.value {
            guard let download = task as? URLSessionDownloadTask,
                  let info = DownloadTaskInfo(taskDescription: task.taskDescription)
            else {
                // Nothing here can route this task's file to a destination —
                // an orphan from an older build, or a non-download task. Drop it
                // rather than leave it consuming bandwidth for no one.
                task.cancel()
                continue
            }
            guard lifecycle.withLock({ $0.restore(info.id, task: task.taskIdentifier) }) else { continue }
            liveIDs.insert(info.id)
            taskMap[task.taskIdentifier] = info.id
            idToTask[info.id] = download
            idToFilename[info.id] = info.filename
            let active = ActiveDownload(id: info.id, title: info.title)
            let expected = task.countOfBytesExpectedToReceive
            if expected > 0 {
                active.totalBytes = expected
                active.bytesWritten = task.countOfBytesReceived
                active.fractionCompleted = Double(task.countOfBytesReceived) / Double(expected)
            }
            activeDownloads[info.id] = active
        }
        Logger.downloads.info("Adopted \(liveIDs.count) in-flight background download(s)")
    }

    /// Stores the completion handler the system hands over when it relaunches
    /// the app to deliver background session events, to be invoked from
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    ///
    /// Reaching this method is also what *recreates* the session: a background
    /// session only delivers its queued events to a session object built with
    /// the same identifier, and `DownloadManager.shared` is lazy, so a
    /// background relaunch would otherwise never touch it.
    func handleBackgroundSessionEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        backgroundCompletionHandler = completionHandler
    }

    // MARK: - Public API

    func startDownload(movie: Movie, playlist: Playlist) {
        let id = movie.id
        // Stalker streams resolve to short-lived URLs per session, so there is no
        // stable URL to download for offline playback.
        guard playlist.supportsDownloads else { return }
        guard activeDownloads[id] == nil, !pendingIDs.contains(id) else { return }
        guard movie.downloadStatus != .completed else { return }

        guard let url = Self.downloadURL(direct: movie.directURL, playlist: playlist, xtream: {
            XtreamClient.buildMovieURL(for: movie, playlist: playlist)
        }) else { return }

        let ext = DownloadFileIdentity.safeExtension(movie.containerExtension)
        let filename = "\(Self.sanitize(id)).\(ext)"
        idToFilename[id] = filename
        enqueue(PendingDownload(id: id, title: movie.name, url: url, filename: filename))
    }

    func startDownload(episode: Episode, playlist: Playlist) {
        let id = episode.id
        guard playlist.supportsDownloads else { return }
        guard activeDownloads[id] == nil, !pendingIDs.contains(id) else { return }
        guard episode.downloadStatus != .completed else { return }

        guard let url = Self.downloadURL(direct: episode.directSource, playlist: playlist, xtream: {
            XtreamClient.buildEpisodeURL(for: episode, playlist: playlist)
        }) else { return }

        let ext = DownloadFileIdentity.safeExtension(episode.containerExtension)
        let filename = "\(Self.sanitize(id)).\(ext)"
        let title = episode.series.map { "\($0.name) S\(episode.seasonNum)E\(episode.episodeNum)" } ?? episode.title
        idToFilename[id] = filename
        enqueue(PendingDownload(id: id, title: title, url: url, filename: filename))
    }

    func cancelDownload(id: String) {
        lifecycle.withLock { $0.cancel(id) }
        if let task = idToTask[id] {
            taskMap.removeValue(forKey: task.taskIdentifier)
            _ = progressPublishGate.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        }
        idToTask[id]?.cancel()
        idToTask.removeValue(forKey: id)
        activeDownloads.removeValue(forKey: id)
        pendingIDs.remove(id)
        pendingQueue.removeAll { $0.id == id }
        scheduleModelUpdate(id: id, status: nil, localURL: nil)
        promoteIfNeeded()
    }

    func deleteLocalFile(id: String) {
        let filename = idToFilename[id]
        if let filename {
            let fileURL = downloadsDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
        } else {
            let sanitizedID = Self.sanitize(id)
            let all = (try? FileManager.default.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil)) ?? []
            for file in all where Self.isDownloadFile(file, for: sanitizedID) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        scheduleModelUpdate(id: id, status: nil, localURL: nil)
    }

    /// If auto-delete is enabled, removes the local file after the content is
    /// marked watched. Call this whenever watched state changes to `true`.
    func checkAutoDelete(id: String) {
        guard UserDefaults.standard.bool(forKey: Self.autoDeleteKey) else { return }
        deleteLocalFile(id: id)
    }

    // MARK: - Status helpers

    func isActive(_ id: String) -> Bool {
        activeDownloads[id] != nil || pendingIDs.contains(id)
    }

    // MARK: - Directory

    /// `nonisolated` so `didFinishDownloadingTo` can resolve the destination and
    /// move the file before returning, without hopping to the main actor first.
    nonisolated var downloadsDirectory: URL {
        DownloadStorage.directory
    }

    // MARK: - Private

    private nonisolated func ensureDownloadsDirectory() {
        try? FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        Self.excludeFromBackup(downloadsDirectory)
    }

    private var maxConcurrent: Int {
        let raw = UserDefaults.standard.integer(forKey: Self.maxConcurrentKey)
        return raw > 0 ? raw : 1
    }

    private func enqueue(_ item: PendingDownload) {
        lifecycle.withLock { $0.enqueue(item.id) }
        DownloadCompletionNotifications.shared.prepareForDownload()
        pendingQueue.append(item)
        pendingIDs.insert(item.id)
        scheduleModelUpdate(id: item.id, status: .pending, localURL: nil)
        promoteIfNeeded()
    }

    private func promoteIfNeeded() {
        let max = maxConcurrent
        while activeDownloads.count < max, !pendingQueue.isEmpty {
            let item = pendingQueue.removeFirst()
            pendingIDs.remove(item.id)
            startTask(item)
        }
    }

    private func startTask(_ item: PendingDownload) {
        let task = session.downloadTask(with: item.url)
        guard lifecycle.withLock({ $0.start(item.id, task: task.taskIdentifier) }) else { task.cancel(); return }
        // Each attempt owns a different file. An old completion that was
        // already moving cannot overwrite a replacement's successfully saved file.
        let base = (item.filename as NSString).deletingPathExtension
        let ext = (item.filename as NSString).pathExtension
        let filename = "\(base).\(UUID().uuidString).\(ext)"
        idToFilename[item.id] = filename
        task.taskDescription = DownloadTaskInfo(
            id: item.id, title: item.title, filename: filename
        ).taskDescription
        taskMap[task.taskIdentifier] = item.id
        idToTask[item.id] = task
        activeDownloads[item.id] = ActiveDownload(id: item.id, title: item.title)
        scheduleModelUpdate(id: item.id, status: .downloading, localURL: nil)
        task.resume()
    }

    private func scheduleModelUpdate(id: String, status: DownloadStatus?, localURL: String?) {
        guard let container = modelContainer else { return }
        let capturedID = id
        let capturedStatus = status
        let capturedURL = localURL
        let previous = statusWrite
        statusWrite = Task.detached {
            await previous?.value
            await DownloadManager.persistStatus(
                id: capturedID,
                status: capturedStatus,
                localURL: capturedURL,
                container: container
            )
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        let taskID = downloadTask.taskIdentifier
        let now = Date()
        let shouldPublish = progressPublishGate.withLock { lastPublish in
            if let last = lastPublish[taskID], now.timeIntervalSince(last) < 0.25 {
                return false
            }
            lastPublish[taskID] = now
            return true
        }
        guard shouldPublish else { return }
        Task { @MainActor in
            guard let id = self.taskMap[taskID], let download = self.activeDownloads[id] else { return }
            download.fractionCompleted = fraction
            download.bytesWritten = totalBytesWritten
            download.totalBytes = totalBytesExpectedToWrite
            // Add a speed sample at most every 500 ms to keep the stats stable.
            let lastSample = download.samples.last?.date ?? .distantPast
            if now.timeIntervalSince(lastSample) >= 0.5 {
                download.samples.append((date: now, bytes: totalBytesWritten))
                download.samples = download.samples.filter { $0.date >= now.addingTimeInterval(-5) }
            }
        }
    }

    nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        let responseURL = downloadTask.response?.url ?? downloadTask.currentRequest?.url
        let ext = DownloadFileIdentity.safeExtension(responseURL?.pathExtension)

        // Resolve the destination from the task itself rather than from any map
        // on the main actor: with a background session this callback can arrive
        // in a process that was relaunched purely to receive it, where those maps
        // are still empty.
        guard let info = DownloadTaskInfo(taskDescription: downloadTask.taskDescription) else {
            finishWithoutTaskInfo(
                taskID: taskID,
                location: location,
                response: downloadTask.response,
                ext: ext
            )
            return
        }
        guard lifecycle.withLock({ $0.beginCompletion(info.id, task: taskID) }) else { return }

        // URLSession deletes `location` the moment this delegate returns, and the
        // process may be suspended before any hop to the main actor runs — so the
        // file has to reach its *final* home synchronously, right here.
        let destination = downloadsDirectory.appendingPathComponent(info.filename)
        do {
            try DownloadValidator.validate(fileAt: location, response: downloadTask.response)
            try moveIntoDownloads(from: location, to: destination)
        } catch {
            Logger.downloads.error("Rejected or failed to save download for \(info.id): \(error)")
            deliverFailure(taskID: taskID, restoredID: info.id)
            return
        }
        Logger.downloads.info("Download complete: \(info.id)")
        completionDeliveryGroup.enter()
        Task { @MainActor in
            defer { self.completionDeliveryGroup.leave() }
            guard self.finalizeDownload(taskID: taskID, info: info) else {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            await self.statusWrite?.value
            await DownloadCompletionNotifications.shared.notifyCompleted(info, taskID: taskID)
        }
    }

    /// Moves a finished transfer into the downloads directory, replacing any
    /// previous file for the same item.
    private nonisolated func moveIntoDownloads(from location: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: downloadsDirectory, withIntermediateDirectories: true
        )
        // Re-apply in case the directory was removed and recreated since
        // launch — a recreated one would carry no exclusion, and every
        // download after that would start being backed up again.
        Self.excludeFromBackup(downloadsDirectory)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: location, to: destination)
    }

    /// Completion path for a task whose `DownloadTaskInfo` could not be decoded.
    /// Only reachable if encoding it failed when the task was created — which,
    /// for three strings, it does not — but a finished multi-gigabyte transfer is
    /// not something to drop on an "impossible" branch. Stages the file out of
    /// `location` (which URLSession deletes on return) so the content id can be
    /// resolved from `taskMap` on the main actor.
    private nonisolated func finishWithoutTaskInfo(
        taskID: Int,
        location: URL,
        response: URLResponse?,
        ext: String
    ) {
        let interim = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-dl", isDirectory: true)
            .appendingPathComponent("\(taskID).\(ext)")
        var staged = true
        do {
            try DownloadValidator.validate(fileAt: location, response: response)
            try FileManager.default.createDirectory(
                at: interim.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: interim.path) {
                try FileManager.default.removeItem(at: interim)
            }
            try FileManager.default.moveItem(at: location, to: interim)
        } catch {
            Logger.downloads.error("Failed to stage download for task \(taskID): \(error)")
            staged = false
        }
        let wasStaged = staged
        completionDeliveryGroup.enter()
        Task { @MainActor in
            defer { self.completionDeliveryGroup.leave() }
            guard let id = self.taskMap[taskID] else {
                try? FileManager.default.removeItem(at: interim)
                return
            }
            let filename = self.idToFilename[id] ?? "\(Self.sanitize(id)).\(ext)"
            self.idToFilename[id] = filename
            let destination = self.downloadsDirectory.appendingPathComponent(filename)
            do {
                guard wasStaged else { throw CocoaError(.fileNoSuchFile) }
                try self.moveIntoDownloads(from: interim, to: destination)
            } catch {
                Logger.downloads.error("Failed to save download for \(id): \(error)")
                try? FileManager.default.removeItem(at: interim)
                self.handleFailure(taskID: taskID, id: id)
                self.promoteIfNeeded()
                return
            }
            Logger.downloads.info("Download complete: \(id)")
            let info = DownloadTaskInfo(id: id, title: self.activeDownloads[id]?.title ?? id, filename: filename)
            guard self.finalizeDownload(
                taskID: taskID,
                info: info
            ) else {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            await self.statusWrite?.value
            await DownloadCompletionNotifications.shared.notifyCompleted(info, taskID: taskID)
        }
    }

    /// Main-actor bookkeeping once the file is already in place: clear the live
    /// maps and persist the completed status.
    @MainActor
    private func finalizeDownload(taskID: Int, info: DownloadTaskInfo) -> Bool {
        guard lifecycle.withLock({ $0.finish(info.id, task: taskID) }) else { return false }
        _ = progressPublishGate.withLock { $0.removeValue(forKey: taskID) }
        idToFilename[info.id] = info.filename
        activeDownloads.removeValue(forKey: info.id)
        taskMap.removeValue(forKey: taskID)
        idToTask.removeValue(forKey: info.id)
        // The filename, not the path: the container path changes on every app
        // update (see `DownloadStorage.file(forStored:)`).
        scheduleModelUpdate(id: info.id, status: .completed, localURL: info.filename)
        promoteIfNeeded()
        return true
    }

    nonisolated func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        // Cancellation is the user tapping the X: `cancelDownload` has already
        // cleared the item's state and status, so recording a failure here would
        // resurrect the row as a failed download.
        if (error as? URLError)?.code == .cancelled {
            return
        }
        let taskID = task.taskIdentifier
        // As in `didFinishDownloadingTo`, the task may outlive the process that
        // started it, so `taskMap` is not guaranteed to know it.
        let restoredID = DownloadTaskInfo(taskDescription: task.taskDescription)?.id
        Logger.downloads.error("Download task failed: \(LogRedaction.describe(error), privacy: .public)")
        deliverFailure(taskID: taskID, restoredID: restoredID)
    }

    /// Failure delivery owns the same background budget as success: admitting
    /// the work before returning prevents finish-events from overtaking it.
    private nonisolated func deliverFailure(taskID: Int, restoredID: String?) {
        completionDeliveryGroup.enter()
        Task { @MainActor in
            defer { self.completionDeliveryGroup.leave() }
            guard let id = self.taskMap[taskID] ?? restoredID else { return }
            self.handleFailure(taskID: taskID, id: id)
            self.promoteIfNeeded()
            await self.statusWrite?.value
        }
    }

    /// The session has delivered every event queued while the app was away.
    /// Releasing the stored handler tells the system the background relaunch is
    /// finished; failing to call it gets the app throttled out of future ones.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        Task { @MainActor in
            await withCheckedContinuation { continuation in
                self.completionDeliveryGroup.notify(queue: .global()) { continuation.resume() }
            }
            await self.statusWrite?.value
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }

    @MainActor
    private func handleFailure(taskID: Int, id: String) {
        guard lifecycle.withLock({ $0.fail(id, task: taskID) }) else { return }
        _ = progressPublishGate.withLock { $0.removeValue(forKey: taskID) }
        activeDownloads.removeValue(forKey: id)
        taskMap.removeValue(forKey: taskID)
        idToTask.removeValue(forKey: id)
        scheduleModelUpdate(id: id, status: .failed, localURL: nil)
    }
}
