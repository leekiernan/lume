import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct DownloadFailureDeliveryTests {
    @Test func `background completion waits for durable failed status`() async throws {
        let container = try makeTestContainer()
        let movie = Movie(id: UUID().uuidString, streamId: 1, name: "Fixture")
        movie.downloadStatus = .downloading
        container.mainContext.insert(movie)
        try container.mainContext.save()
        let manager = DownloadManager(sessionConfiguration: .ephemeral)
        defer { manager.invalidateSession() }
        manager.configure(container: container)
        let transport = URLSession(configuration: .ephemeral)
        defer { transport.invalidateAndCancel() }
        let task = try transport.downloadTask(with: #require(URL(string: "https://fixture.test/movie")))
        task.taskDescription = DownloadTaskInfo(id: movie.id, title: movie.name, filename: "fixture.mp4").taskDescription
        await withCheckedContinuation { continuation in
            manager.handleBackgroundSessionEvents(identifier: "bilipp.Lume.downloads") { continuation.resume() }
            manager.urlSession(transport, task: task, didCompleteWithError: URLError(.networkConnectionLost))
            manager.urlSessionDidFinishEvents(forBackgroundURLSession: transport)
        }
        let stored = try #require(ModelContext(container).fetch(FetchDescriptor<Movie>()).first)
        #expect(stored.downloadStatus == .failed)
    }
}
