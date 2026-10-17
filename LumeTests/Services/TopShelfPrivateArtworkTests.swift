#if canImport(UIKit)
    import Foundation
    @testable import Lume
    import Testing
    import UIKit

    @MainActor
    struct TopShelfPrivateArtworkTests {
        private func snapshot(token: String) -> WidgetSnapshot {
            let item = WidgetMediaItem(
                id: "account-00000000-0000-0000-0000-000000000000-movie-1", kind: .movie, title: "Private",
                imageURL: URL(string: "https://server.test/photo?X-Plex-Token=\(token)"),
                backdropURL: URL(string: "https://public.test/backdrop.jpg"), deepLink: URL(string: "lume://open/movie/1")!
            )
            return WidgetSnapshot(generatedAt: .now, sections: [WidgetSection(id: "row", title: "Row", items: [item])])
        }

        @Test func `shared snapshot sanitization drops credentials but retains public images`() throws {
            let safe = snapshot(token: "private-secret").withoutArtworkCredentials
            let item = try #require(safe.sections.first?.items.first)
            #expect(item.imageURL == nil)
            #expect(item.backdropURL == URL(string: "https://public.test/backdrop.jpg"))
            let json = try JSONEncoder().encode(safe)
            #expect(String(data: json, encoding: .utf8)?.contains("private-secret") == false)
        }

        @Test func `authenticated art becomes a reusable file without exporting the token`() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = snapshot(token: "private-secret")
            var exported = source
            TopShelfPrivateArtwork.applyCached(to: &exported, directory: directory)
            #expect(exported.sections[0].items[0].imageURL == nil)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
            let cgImage = try #require(image.cgImage)
            let changed = await TopShelfPrivateArtwork.renderMissing(in: &exported, source: source, directory: directory) { _, _ in cgImage }
            #expect(changed)
            let file = try #require(exported.sections[0].items[0].imageURL)
            #expect(file.isFileURL && FileManager.default.fileExists(atPath: file.path))
            var reopened = snapshot(token: "private-secret")
            TopShelfPrivateArtwork.applyCached(to: &reopened, directory: directory)
            #expect(reopened.sections[0].items[0].imageURL == file)
            var anotherAccount = snapshot(token: "another-account-secret")
            TopShelfPrivateArtwork.applyCached(to: &anotherAccount, directory: directory)
            #expect(anotherAccount.sections[0].items[0].imageURL == nil)
            #expect(exported == exported.withoutArtworkCredentials)
        }
    }
#endif
