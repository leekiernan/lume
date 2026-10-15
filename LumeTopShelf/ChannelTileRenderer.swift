//
//  ChannelTileRenderer.swift
//  LumeTopShelf
//
//  Turns a channel logo into a finished Top Shelf tile. The Top Shelf fills
//  its card with whatever image it is handed, so a raw logo — usually a small,
//  wide, transparent PNG — came out stretched and cropped. Instead the logo is
//  drawn aspect-fit and centred, with room around it, on a square tile whose
//  colour keeps it readable (`LogoBackdrop`). A channel without a usable logo
//  gets its name. Tiles are cached (`TopShelfImages`) and handed to the Top
//  Shelf as file URLs.
//

import UIKit

enum ChannelTileRenderer {
    /// Square, matching the `.square` item shape the channels use — it lines
    /// up with the poster rows; a 16:9 card fit only two channels on screen.
    static let tileSize = CGSize(width: 600, height: 600)
    /// The share of the tile a logo may cover, so it never touches the edges.
    private static let logoBox = CGSize(width: tileSize.width * 0.8, height: tileSize.height * 0.5)
    /// Bumped whenever the drawing changes, so stale tiles aren't reused.
    private static let renderVersion = 6

    /// File URLs of the rendered tiles, keyed by `Channel.id`. Logos download
    /// in parallel; a tile already on disk is reused, and tiles no longer in
    /// use are deleted.
    static func tiles(for channels: [Channel]) async -> [String: URL] {
        guard let directory = TopShelfImages.directory("TopShelfChannelTiles") else { return [:] }
        // The same channel can appear more than once: render it once.
        let unique = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let rendered = await TopShelfImages.boundedMap(Array(unique)) { channel in
            await (channel.id, tile(for: channel, in: directory))
        }
        let tiles = Dictionary(rendered.compactMap { id, url in url.map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
        guard !Task.isCancelled else { return tiles }
        TopShelfImages.prune(directory, keeping: Set(tiles.values.map(\.lastPathComponent)))
        return tiles
    }

    struct Channel {
        let id: String
        let name: String
        let logoURL: URL?
    }

    // MARK: - Tile

    private static func tile(for channel: Channel, in directory: URL) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let file = directory.appendingPathComponent(fileName(for: channel, logoURL: channel.logoURL))
        if FileManager.default.fileExists(atPath: file.path) { return file }
        var logo: CGImage?
        if let logoURL = channel.logoURL {
            logo = await TopShelfImages.download(logoURL, maxPixelSize: Int(logoBox.width))
        }
        // A logo that failed to download gets the name tile under the
        // name-only key, so the next load tries the logo again rather than
        // keeping the fallback for good.
        let target = logo == nil && channel.logoURL != nil
            ? directory.appendingPathComponent(fileName(for: channel, logoURL: nil))
            : file
        guard !Task.isCancelled else { return nil }
        return autoreleasepool { TopShelfImages.write(render(logo: logo, name: channel.name), to: target) }
    }

    /// Keyed by what the tile shows, so a changed logo or name renders anew.
    private static func fileName(for channel: Channel, logoURL: URL?) -> String {
        TopShelfImages.fileName(for: "\(renderVersion)|\(logoURL?.absoluteString ?? "")|\(channel.name)")
    }

    private static func render(logo: CGImage?, name: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // The name fallback is light text, so it always sits on dark.
        let backdrop = logo.map { LogoBackdrop.choose(for: $0) } ?? .dark
        return UIGraphicsImageRenderer(size: tileSize, format: format).image { context in
            backdrop.color.setFill()
            context.fill(CGRect(origin: .zero, size: tileSize))
            if let logo {
                UIImage(cgImage: logo).draw(in: fittedRect(for: CGSize(width: logo.width, height: logo.height)))
            } else {
                drawName(name)
            }
        }
    }

    /// The logo scaled to fit `logoBox` without distortion, centred. Small
    /// logos scale up to fill the box; nothing is ever cropped.
    private static func fittedRect(for size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(logoBox.width / size.width, logoBox.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (tileSize.width - fitted.width) / 2,
            y: (tileSize.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private static func drawName(_ name: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 64, weight: .semibold),
            .foregroundColor: UIColor(white: 0.92, alpha: 1),
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(string: name, attributes: attributes)
        // Measured unbounded, then rounded up: a rect even a fraction short of
        // the text's height truncates its last line.
        let bounds = text.boundingRect(
            with: CGSize(width: logoBox.width, height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin,
            context: nil
        )
        let height = min(bounds.height.rounded(.up), logoBox.height)
        text.draw(with: CGRect(
            x: (tileSize.width - logoBox.width) / 2,
            y: (tileSize.height - height) / 2,
            width: logoBox.width,
            height: height
        ), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}
