import Foundation
@testable import Lume
import Testing
import UIKit

/// The carousel art the export renders: backdrop plus logo, written as JPEG
/// to a folder the test owns, from fixture images on disk.
struct TopShelfCarouselArtTests {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("TopShelfCarouselArtTests-\(UUID().uuidString)", isDirectory: true)

    private func fixture(_ name: String, size: CGSize, draw: (CGContext) -> Void) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
        let url = folder.appendingPathComponent(name)
        try #require(image.pngData()).write(to: url)
        return url
    }

    /// A bright, busy backdrop — the hard case for a light logo.
    private func backdrop() throws -> URL {
        try fixture("backdrop.png", size: CGSize(width: 1280, height: 720)) { context in
            let colors = [UIColor.systemYellow.cgColor, UIColor.systemTeal.cgColor] as CFArray
            let gradient = try? #require(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]))
            gradient.map { context.drawLinearGradient($0, start: .zero, end: CGPoint(x: 1280, y: 720), options: []) }
        }
    }

    private func logo(_ name: String, color: UIColor) throws -> URL {
        try fixture(name, size: CGSize(width: 500, height: 160)) { _ in
            ("LUME" as NSString).draw(at: CGPoint(x: 10, y: 10), withAttributes: [
                .font: UIFont.systemFont(ofSize: 120, weight: .black),
                .foregroundColor: color
            ])
        }
    }

    private func item(_ id: String, kind: WidgetMediaItem.Kind = .movie, backdrop: URL?, logo: URL?) throws -> WidgetMediaItem {
        try WidgetMediaItem(
            id: id, kind: kind, title: id, subtitle: nil, imageURL: nil, backdropURL: backdrop,
            progress: nil, deepLink: #require(URL(string: "lume://play/movie/\(id)")), detailLink: nil, logoURL: logo
        )
    }

    @Test func `titles with a logo get rendered art, the rest keep their backdrop`() async throws {
        let backdrop = try backdrop()
        let light = try logo("light.png", color: .white)
        let dark = try logo("dark.png", color: .black)
        var snapshot = try WidgetSnapshot(generatedAt: Date(), sections: [WidgetSection(id: "row", title: "Row", items: [
            item("light", backdrop: backdrop, logo: light),
            item("dark", backdrop: backdrop, logo: dark),
            item("no-logo", backdrop: backdrop, logo: nil),
            item("channel", kind: .live, backdrop: backdrop, logo: light)
        ])])

        let rendered = await TopShelfCarouselArt.renderMissing(in: &snapshot, directory: folder)

        #expect(rendered)
        let items = snapshot.sections[0].items
        for item in items.prefix(2) {
            let art = try #require(item.artURL)
            #expect(art.pathExtension == "jpg")
            let image = try #require(UIImage(contentsOfFile: art.path))
            #expect(image.size == TopShelfCarouselArt.canvas)
            print("Rendered carousel art (\(item.id)): \(art.path)")
        }
        #expect(items[2].artURL == nil && items[3].artURL == nil)
    }

    /// The next export finds the art without rendering, so an unchanged
    /// snapshot writes nothing.
    @Test func `rendered art is found again without rendering`() async throws {
        let backdrop = try backdrop()
        let light = try logo("light.png", color: .white)
        let fresh = try WidgetSnapshot(generatedAt: Date(), sections: [WidgetSection(id: "row", title: "Row", items: [
            item("light", backdrop: backdrop, logo: light)
        ])])
        var first = fresh
        _ = await TopShelfCarouselArt.renderMissing(in: &first, directory: folder)

        var second = fresh
        TopShelfCarouselArt.applyCached(to: &second, in: folder)
        #expect(second.sections == first.sections)
        #expect(await !TopShelfCarouselArt.renderMissing(in: &second, directory: folder))
    }
}
