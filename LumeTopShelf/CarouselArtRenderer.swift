//
//  CarouselArtRenderer.swift
//  LumeTopShelf
//
//  The carousel's full-width art with the title's logo in its top-left
//  corner, where Apple TV+ puts it: the in-app hero shows the same wordmark
//  over the same backdrop. The Top Shelf shows one image per item, so the logo
//  is drawn into it, over a soft shade from that corner so it reads on any
//  backdrop. Rendered images are cached (`TopShelfImages`) and handed to the
//  Top Shelf as file URLs; a title without a logo, or whose images fail to
//  download, keeps its plain backdrop and is tried again next time.
//

import UIKit

enum CarouselArtRenderer {
    /// The Top Shelf carousel's image size.
    static let canvas = CGSize(width: 1920, height: 1080)
    /// The logo is fitted into this box, its top-left corner at `inset` — the
    /// TV-safe margin, clear of the carousel's own title and summary below.
    private static let logoBox = CGSize(width: 640, height: 240)
    private static let inset = CGPoint(x: 96, y: 80)
    /// Bumped whenever the drawing changes, so stale images aren't reused.
    private static let renderVersion = 1

    struct Art {
        let id: String
        let backdropURL: URL
        let logoURL: URL?
    }

    /// File URLs of the rendered images, keyed by `Art.id` — only for art
    /// with a logo that rendered. Downloads run in parallel; an image already
    /// on disk is reused, and images no longer shown are deleted.
    static func images(for art: [Art]) async -> [String: URL] {
        guard let directory = TopShelfImages.directory("TopShelfCarouselArt") else { return [:] }
        let images = await withTaskGroup(of: (String, URL?).self) { group in
            for item in art where item.logoURL != nil {
                group.addTask { await (item.id, image(for: item, in: directory)) }
            }
            var result: [String: URL] = [:]
            for await (id, url) in group {
                if let url { result[id] = url }
            }
            return result
        }
        TopShelfImages.prune(directory, keeping: Set(images.values.map(\.lastPathComponent)))
        return images
    }

    private static func image(for art: Art, in directory: URL) async -> URL? {
        guard let logoURL = art.logoURL else { return nil }
        let name = TopShelfImages.fileName(for: "\(renderVersion)|\(art.backdropURL.absoluteString)|\(logoURL.absoluteString)")
        let file = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        async let backdrop = TopShelfImages.download(art.backdropURL, maxPixelSize: Int(canvas.width))
        async let logo = TopShelfImages.download(logoURL, maxPixelSize: Int(logoBox.width))
        guard let backdrop = await backdrop, let logo = await logo else { return nil }
        return TopShelfImages.write(render(backdrop: backdrop, logo: logo), to: file)
    }

    private static func render(backdrop: CGImage, logo: CGImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIImage(cgImage: backdrop).draw(in: aspectFill(size(of: backdrop), in: canvas))
            shade(behind: logo, in: context.cgContext)
            UIImage(cgImage: logo).draw(in: logoRect(for: size(of: logo)))
        }
    }

    /// A radial shade from the top-left corner, in the colour the logo reads
    /// on: dark behind a light wordmark, light behind a dark one.
    private static func shade(behind logo: CGImage, in context: CGContext) {
        let backdrop = LogoBackdrop.choose(for: logo)
        let alpha: CGFloat = switch backdrop {
        case .dark: 0.55
        case .light: 0.35
        case .neutral: 0.3
        }
        let colors = [backdrop.color.withAlphaComponent(alpha).cgColor, backdrop.color.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: .zero, startRadius: 0,
            endCenter: .zero, endRadius: canvas.width * 0.6,
            options: []
        )
    }

    private static func logoRect(for logo: CGSize) -> CGRect {
        let scale = min(logoBox.width / logo.width, logoBox.height / logo.height)
        return CGRect(origin: inset, size: CGSize(width: logo.width * scale, height: logo.height * scale))
    }

    private static func aspectFill(_ image: CGSize, in canvas: CGSize) -> CGRect {
        let scale = max(canvas.width / image.width, canvas.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
    }

    private static func size(of image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }
}
