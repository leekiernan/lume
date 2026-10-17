import Foundation
@testable import Lume
import Testing

@MainActor
struct OpenSubtitlesSessionTests {
    private let account = OpenSubtitlesSession(token: "test-token", username: "viewer", host: "example.invalid", allowedDownloads: 10)

    @Test func `logout revokes a suspended login and its error`() async {
        let gate = SubtitleTestGate<OpenSubtitlesSession>()
        let client = SubtitleTestClient()
        client.loginBody = { try await gate.wait() }
        let storage = SubtitleTestStorage()
        let service = makeService(client, storage)
        let login = Task { await service.signIn(username: "viewer", password: "test") }
        await gate.entered()
        #expect(service.isSigningIn)
        await service.signOut()
        gate.finish(.success(account))
        await login.value
        #expect(!service.isSignedIn)
        #expect(!service.isSigningIn)
        #expect(storage.saved == nil)
        #expect(service.signInError == nil)

        let failedGate = SubtitleTestGate<OpenSubtitlesSession>()
        client.loginBody = { try await failedGate.wait() }
        let failure = Task { await service.signIn(username: "viewer", password: "test") }
        await failedGate.entered()
        await service.signOut()
        failedGate.finish(.failure(OpenSubtitlesError.invalidCredentials))
        await failure.value
        #expect(service.signInError == nil)
    }

    @Test func `old remote logout cannot clear a new account`() async {
        let gate = SubtitleTestGate<Void>()
        let client = SubtitleTestClient()
        client.logoutBody = { try await gate.wait() }
        client.loginBody = { account }
        let storage = SubtitleTestStorage()
        storage.saved = account
        let service = makeService(client, storage)
        service.restore()
        let logout = Task { await service.signOut() }
        await gate.entered()
        #expect(!service.isSignedIn)
        await service.signIn(username: "viewer", password: "test")
        gate.finish(.success(()))
        await logout.value
        #expect(service.username == "viewer")
        #expect(storage.saved == account)
    }

    @Test(arguments: [false, true]) func `logout rejects a download at either suspension point`(afterLink: Bool) async throws {
        let linkGate = SubtitleTestGate<OpenSubtitlesDownload>()
        let fileGate = SubtitleTestGate<Data>()
        let client = SubtitleTestClient()
        let link = try OpenSubtitlesDownload(link: #require(URL(string: "https://example.invalid/subtitle")), fileName: "test.srt", remainingDownloads: 9)
        client.linkBody = { afterLink ? link : try await linkGate.wait() }
        client.fetchBody = { try await fileGate.wait() }
        let storage = SubtitleTestStorage()
        storage.saved = account
        let service = makeService(client, storage)
        service.restore()
        let download = Task { try await service.download(Self.subtitle) }
        if afterLink { await fileGate.entered() } else { await linkGate.entered() }
        await service.signOut()
        if afterLink { fileGate.finish(.success(Data("subtitle".utf8))) } else { linkGate.finish(.success(link)) }
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(service.remainingDownloads == nil)
        #expect(storage.cacheWrites == 0)
        #expect(storage.cacheClears == 1)
    }

    @Test func `a current download records quota and caches the file`() async throws {
        let client = SubtitleTestClient()
        client.linkBody = { OpenSubtitlesDownload(link: URL(string: "https://example.invalid/subtitle")!, fileName: "test.srt", remainingDownloads: 9) }
        client.fetchBody = { Data("subtitle".utf8) }
        let storage = SubtitleTestStorage()
        storage.saved = account
        let service = makeService(client, storage)
        service.restore()
        _ = try await service.download(Self.subtitle)
        #expect(service.remainingDownloads == 9)
        #expect(service.allowedDownloads == 10)
        #expect(storage.cacheWrites == 1)
    }

    @Test func `replacing an account revokes downloads begun during login`() async {
        let loginGate = SubtitleTestGate<OpenSubtitlesSession>()
        let fileGate = SubtitleTestGate<Data>()
        let client = SubtitleTestClient()
        client.loginBody = { try await loginGate.wait() }
        client.linkBody = { OpenSubtitlesDownload(link: URL(string: "https://example.invalid/subtitle")!, fileName: "test.srt", remainingDownloads: 9) }
        client.fetchBody = { try await fileGate.wait() }
        let storage = SubtitleTestStorage()
        storage.saved = account
        let service = makeService(client, storage)
        service.restore()
        let login = Task { await service.signIn(username: "next", password: "test") }
        await loginGate.entered()
        let download = Task { try await service.download(Self.subtitle) }
        await fileGate.entered()
        var next = account
        next.username = "next"
        next.token = "next-test-token"
        loginGate.finish(.success(next))
        await login.value
        fileGate.finish(.success(Data("subtitle".utf8)))
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(service.username == "next")
        #expect(service.remainingDownloads == nil)
        #expect(storage.cacheWrites == 0)
    }

    @Test func `cancelled login does not persist credentials or leave signing in stuck`() async {
        let gate = SubtitleTestGate<OpenSubtitlesSession>()
        let client = SubtitleTestClient()
        client.loginBody = { try await gate.wait() }
        let storage = SubtitleTestStorage()
        let service = makeService(client, storage)
        let login = Task { await service.signIn(username: "viewer", password: "test") }
        await gate.entered()
        login.cancel()
        gate.finish(.success(account))
        await login.value
        #expect(!service.isSigningIn)
        #expect(!service.isSignedIn)
        #expect(storage.saved == nil)
        #expect(service.signInError == nil)
    }

    private func makeService(_ client: SubtitleTestClient, _ storage: SubtitleTestStorage) -> OpenSubtitlesService {
        OpenSubtitlesService(
            client: client,
            persistence: OpenSubtitlesPersistence(load: { storage.saved }, save: { storage.saved = $0 }, clear: { storage.saved = nil }),
            cache: OpenSubtitlesCache(
                cachedFile: { _ in nil },
                store: { _, _ in
                    storage.cacheWrites += 1
                    return URL(fileURLWithPath: "/unused-test-subtitle.srt")
                },
                clear: { storage.cacheClears += 1 }
            )
        )
    }

    private static let subtitle = OnlineSubtitle(
        id: "1", fileID: 1, languageCode: "en", releaseName: "test", downloadCount: 0,
        isHearingImpaired: false, isMachineTranslated: false, isFromTrusted: false, rating: 0
    )
}

@MainActor
private final class SubtitleTestStorage {
    var saved: OpenSubtitlesSession?
    var cacheWrites = 0
    var cacheClears = 0
}

@MainActor
private final class SubtitleTestClient: OpenSubtitlesProviding {
    let isConfigured = true
    var loginBody: () async throws -> OpenSubtitlesSession = { throw OpenSubtitlesError.invalidCredentials }
    var logoutBody: () async throws -> Void = {}
    var linkBody: () async throws -> OpenSubtitlesDownload = { throw OpenSubtitlesError.notAuthenticated }
    var fetchBody: () async throws -> Data = { throw OpenSubtitlesError.invalidResponse }

    func login(username _: String, password _: String, host _: String) async throws -> OpenSubtitlesSession {
        try await loginBody()
    }

    func logout(session _: OpenSubtitlesSession) async throws {
        try await logoutBody()
    }

    func search(_: OpenSubtitlesQuery, host _: String, token _: String?) async throws -> [OnlineSubtitle] {
        []
    }

    func languages(host _: String) async throws -> [OpenSubtitlesLanguage] {
        []
    }

    func downloadLink(for _: OnlineSubtitle, session _: OpenSubtitlesSession) async throws -> OpenSubtitlesDownload {
        try await linkBody()
    }

    func fetch(_: OpenSubtitlesDownload) async throws -> Data {
        try await fetchBody()
    }
}

@MainActor
private final class SubtitleTestGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation {
            continuation = $0
            observer?.resume()
            observer = nil
        }
    }

    func entered() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func finish(_ result: Result<Value, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
