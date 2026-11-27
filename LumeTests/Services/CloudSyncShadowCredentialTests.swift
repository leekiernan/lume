import Foundation
@testable import Lume
import Testing

/// The playlist sync baseline lives in `UserDefaults`, so it must never hold a
/// provider's credentials — only a digest the three-way merge can compare.
struct CloudSyncShadowCredentialTests {
    private static let secret = "hunter2-provider-secret"

    private static func values(
        password: String = secret,
        syncFrequencyRaw: String? = "daily",
        macAddress: String = ""
    ) -> PlaylistConfigValues {
        PlaylistConfigValues(
            name: "Provider",
            serverURL: "http://example.com/get.php?username=viewer&password=\(secret)",
            username: "viewer",
            password: password,
            macAddress: macAddress,
            sourceTypeRaw: "m3u",
            epgURL: "http://example.com/xmltv.php?username=viewer&password=\(secret)",
            syncEnabled: true,
            syncFrequencyRaw: syncFrequencyRaw
        )
    }

    private static func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "CloudSyncShadowCredentialTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func `encoding writes a fingerprint and no credentials`() throws {
        let json = try #require(String(data: JSONEncoder().encode(Self.values()), encoding: .utf8))
        #expect(!json.contains(Self.secret))
        #expect(!json.contains("viewer"))
        #expect(json.contains("fingerprint"))
    }

    @Test func `a decoded baseline compares equal only to the same configuration`() throws {
        let decoded = try JSONDecoder().decode(PlaylistConfigValues.self, from: JSONEncoder().encode(Self.values()))
        #expect(decoded == Self.values())
        #expect(decoded != Self.values(password: "rotated"))
        #expect(decoded != Self.values(syncFrequencyRaw: nil))
        #expect(decoded.password.isEmpty)
    }

    @Test func `a plaintext baseline migrates without reading as a change`() throws {
        let plaintext = """
        {"name":"Provider","serverURL":"http://example.com/get.php?username=viewer&password=\(Self.secret)",\
        "username":"viewer","password":"\(Self.secret)","sourceTypeRaw":"m3u",\
        "epgURL":"http://example.com/xmltv.php?username=viewer&password=\(Self.secret)",\
        "syncEnabled":true,"syncFrequencyRaw":"daily"}
        """
        let decoded = try JSONDecoder().decode(PlaylistConfigValues.self, from: Data(plaintext.utf8))
        // No `macAddress` key (pre-Stalker): it falls back to "".
        #expect(decoded == Self.values())
        #expect(decoded.decodedFromPlaintext)
        #expect(decoded.password.isEmpty)
    }

    @Test func `the shadow rewrites a plaintext baseline as soon as it loads`() throws {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "cloudsync.shadow.playlists.v1"
        let id = UUID().uuidString
        let plaintext = """
        {"\(id)":{"name":"Provider","serverURL":"http://example.com/get.php?username=viewer&password=\(Self.secret)",\
        "username":"viewer","password":"\(Self.secret)","macAddress":"","sourceTypeRaw":"m3u",\
        "epgURL":"http://example.com/xmltv.php?username=viewer&password=\(Self.secret)",\
        "syncEnabled":true,"syncFrequencyRaw":"daily"}}
        """
        defaults.set(Data(plaintext.utf8), forKey: key)

        let shadow = CloudSyncShadow(defaults: defaults)

        let stored = try #require(defaults.data(forKey: key))
        #expect(!(String(data: stored, encoding: .utf8) ?? "").contains(Self.secret))
        #expect(shadow.playlistShadow(id) == Self.values())
        #expect(CloudSyncShadow(defaults: defaults).playlistShadow(id) == Self.values())
    }

    private static let guideURL = "http://example.com/xmltv.php?username=viewer&password=\(secret)"

    @Test func `a guide source baseline holds a fingerprint, not its URL`() throws {
        let live = EPGSourceValues(name: "Guide", url: Self.guideURL, isEnabled: true)
        let data = try JSONEncoder().encode(live)
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains(Self.secret))

        let decoded = try JSONDecoder().decode(EPGSourceValues.self, from: data)
        #expect(decoded == live)
        #expect(decoded != EPGSourceValues(name: "Guide", url: Self.guideURL, isEnabled: false))
        #expect(decoded.url.isEmpty)
    }

    @Test func `the shadow rewrites a plaintext guide source baseline as soon as it loads`() throws {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "cloudsync.shadow.epgsources.v1"
        let id = UUID().uuidString
        let plaintext = """
        {"\(id)":{"name":"Guide","url":"\(Self.guideURL)","isEnabled":true}}
        """
        defaults.set(Data(plaintext.utf8), forKey: key)

        let shadow = CloudSyncShadow(defaults: defaults)

        let stored = try #require(defaults.data(forKey: key))
        #expect(!(String(data: stored, encoding: .utf8) ?? "").contains(Self.secret))
        let live = EPGSourceValues(name: "Guide", url: Self.guideURL, isEnabled: true)
        #expect(shadow.epgSourceShadow(id) == live)
        #expect(CloudSyncShadow(defaults: defaults).epgSourceShadow(id) == live)
    }

    @Test func `a persisted baseline holds no credentials`() throws {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let shadow = CloudSyncShadow(defaults: defaults)
        let id = UUID().uuidString
        shadow.setPlaylistShadow(id, Self.values())
        shadow.persist()

        let stored = try #require(defaults.data(forKey: "cloudsync.shadow.playlists.v1"))
        #expect(!(String(data: stored, encoding: .utf8) ?? "").contains(Self.secret))
        #expect(CloudSyncShadow(defaults: defaults).playlistShadow(id) == Self.values())
    }
}
