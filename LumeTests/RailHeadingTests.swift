@testable import Lume
import SwiftUI
import Testing

@MainActor
struct RailHeadingTests {
    @Test func `a heading without a destination stays the size of plain title text`() throws {
        let title = Text(verbatim: "Favorites")
        let heading = RailHeading<String>(title: title, destination: nil)
        let actual = try size(of: heading.fixedSize())
        let expected = try size(of: title.railHeadingStyle().fixedSize())
        #expect(actual == expected)
    }

    @Test func `a collection heading adds only the inline icon and its spacing`() throws {
        let title = Text(verbatim: "Favorites")
        let plain = try size(of: RailHeading<String>(title: title, destination: nil).fixedSize())
        let linked = try size(of: RailHeading(title: title, destination: "collection").fixedSize())
        // No trailing button, spacer or default button-style inset widens the
        // focusable title. tvOS uses the same heading with a larger icon.
        #expect(linked.width == plain.width + 20 + 8)
        #expect(linked.height == max(plain.height, 20))
    }

    @Test(arguments: [CGFloat(320), 768, 1200])
    func `headings fit the same row width with or without navigation`(_ width: CGFloat) throws {
        for destination in [String?.none, "collection"] {
            let heading = RailHeading(title: Text(verbatim: "A collection title"), destination: destination)
            let actual = try size(of: heading.frame(width: width))
            #expect(actual.width == width)
        }
    }

    @Test func `read more outline scales and centers without distortion`() {
        let icon = ReadMoreIcon()
        let reference = icon.path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).boundingRect
        #expect(abs(reference.minX - 2) < 0.001)
        #expect(abs(reference.maxX - 22) < 0.001)
        let doubled = icon.path(in: CGRect(x: 10, y: 20, width: 48, height: 48)).boundingRect
        #expect(abs(doubled.width - reference.width * 2) < 0.001)
        #expect(abs(doubled.height - reference.height * 2) < 0.001)
        #expect(abs(doubled.minX - (10 + reference.minX * 2)) < 0.001)
        let wide = icon.path(in: CGRect(x: 0, y: 0, width: 48, height: 24)).boundingRect
        #expect(wide.width == reference.width)
        #expect(wide.height == reference.height)
        #expect(abs(wide.midX - 24) < 0.001)
    }

    private func size(of view: some View) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }
}
