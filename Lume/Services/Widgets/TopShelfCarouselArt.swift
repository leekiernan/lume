//
//  TopShelfCarouselArt.swift
//  Lume
//
//  The carousel's full-width art with the title's logo in its top-left
//  corner, where Apple TV+ puts it: the in-app hero shows the same wordmark
//  over the same backdrop. The Top Shelf shows one image per item, so the logo
//  is drawn into it, over a soft shade from that corner so it reads on any
//  backdrop.
//
//  Rendered here, by the export, not in the extension: a Top Shelf extension
//  has a few tens of megabytes and is killed past them, and drawing a
//  carousel's worth of 1920×1080 images at once got it killed before it
//  answered — the Top Shelf fell back to the app's artwork. The app renders
//  a few at a time, writes small JPEGs to the App Group's Caches and records
//  each one's file in the snapshot (`WidgetMediaItem.artURL`); the extension
//  only reads them. A title without a logo, or whose images fail to
//  download, keeps its plain backdrop and is tried again at the next export.
//
//  Only tvOS exports it; it builds wherever UIKit does so its drawing can be
//  tested.
//

#if canImport(UIKit)
    import UIKit

    nonisolated enum TopShelfCarouselArt {
        /// The Top Shelf carousel's image size.
        static let canvas = CGSize(width: 1920, height: 1080)
        /// The logo is fitted into this box, its top-left corner at `inset` —
        /// the TV-safe margin, clear of the carousel's own title and summary.
        private static let logoBox = CGSize(width: 640, height: 240)
        private static let inset = CGPoint(x: 96, y: 80)
        /// How many titles render at once: each holds a decoded backdrop and
        /// a canvas, so this bounds the export's memory too.
        private static let concurrency = 3
        /// Bumped whenever the drawing changes, so stale images aren't reused.
        private static let renderVersion = 2
        /// In the App Group's Caches, where the extension reads it. Tests
        /// pass their own folder.
        static var defaultDirectory: URL? {
            TopShelfImages.directory("TopShelfCarouselArt")
        }

        /// Points every item at art already on disk, with no downloads — so an
        /// export that changes nothing writes nothing.
        static func applyCached(to snapshot: inout WidgetSnapshot, in directory: URL? = defaultDirectory) {
            guard let directory else { return }
            update(&snapshot) { item in
                guard let file = file(for: item, in: directory) else { return nil }
                return FileManager.default.fileExists(atPath: file.path) ? file : nil
            }
        }

        /// Renders the art the snapshot's items don't have yet and points them
        /// at it. Returns whether any item gained art.
        /// How an image is fetched: `TopShelfImages.download`, or a test's
        /// reader of local fixtures.
        typealias Loader = @Sendable (URL, Int) async -> CGImage?

        static func renderMissing(
            in snapshot: inout WidgetSnapshot,
            directory: URL? = defaultDirectory,
            load: @escaping Loader = { await TopShelfImages.loadArtwork($0, maxPixelSize: $1) }
        ) async -> Bool {
            guard let directory else { return false }
            var pending: [URL: Request] = [:]
            for section in snapshot.sections {
                for item in section.items where item.artURL == nil {
                    if let request = Request(item), let file = file(for: item, in: directory) {
                        pending[file] = request
                    }
                }
            }
            var rendered: Set<URL> = []
            let work = Array(pending)
            for start in stride(from: 0, to: work.count, by: concurrency) {
                guard !Task.isCancelled else { return false }
                let batch = work[start ..< min(start + concurrency, work.count)]
                await withTaskGroup(of: URL?.self) { group in
                    for (file, request) in batch {
                        group.addTask { await render(request, to: file, load: load) }
                    }
                    for await file in group {
                        if let file { rendered.insert(file) }
                    }
                }
            }
            guard !rendered.isEmpty else { return false }
            update(&snapshot) { item in
                file(for: item, in: directory).flatMap { rendered.contains($0) ? $0 : nil }
            }
            return true
        }

        /// Deletes art no item of `snapshot` uses.
        static func prune(keeping snapshot: WidgetSnapshot, in directory: URL? = defaultDirectory) {
            guard let directory else { return }
            let used = snapshot.sections.flatMap(\.items).compactMap(\.artURL?.lastPathComponent)
            TopShelfImages.prune(directory, keeping: Set(used))
        }

        // MARK: - Rendering

        /// What one image is drawn from.
        private struct Request {
            let backdrop: URL
            let logo: URL

            init?(_ item: WidgetMediaItem) {
                guard item.kind != .live, let backdrop = item.backdropURL, let logo = item.logoURL else { return nil }
                self.backdrop = backdrop
                self.logo = logo
            }
        }

        /// Keyed by what the image shows, so a changed backdrop or logo
        /// renders anew.
        private static func file(for item: WidgetMediaItem, in directory: URL) -> URL? {
            guard let request = Request(item) else { return nil }
            let key = "\(renderVersion)|\(request.backdrop.absoluteString)|\(request.logo.absoluteString)"
            return directory.appendingPathComponent(TopShelfImages.fileName(for: key, extension: "jpg"))
        }

        private static func update(_ snapshot: inout WidgetSnapshot, art: (WidgetMediaItem) -> URL?) {
            for section in snapshot.sections.indices {
                for index in snapshot.sections[section].items.indices {
                    let item = snapshot.sections[section].items[index]
                    if item.artURL == nil, let file = art(item) {
                        snapshot.sections[section].items[index].artURL = file
                    }
                }
            }
        }

        private static func render(_ request: Request, to file: URL, load: Loader) async -> URL? {
            guard !Task.isCancelled else { return nil }
            if FileManager.default.fileExists(atPath: file.path) { return file }
            async let backdrop = load(request.backdrop, Int(canvas.width))
            async let logo = load(request.logo, Int(logoBox.width))
            guard let backdrop = await backdrop, let logo = await logo, !Task.isCancelled else { return nil }
            return autoreleasepool {
                TopShelfImages.writeJPEG(draw(backdrop: backdrop, logo: logo), to: file)
            }
        }

        private static func draw(backdrop: CGImage, logo: CGImage) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
                UIImage(cgImage: backdrop).draw(in: aspectFill(size(of: backdrop), in: canvas))
                shade(behind: logo, in: context.cgContext)
                UIImage(cgImage: logo).draw(in: logoRect(for: size(of: logo)))
            }
        }

        /// A radial shade from the top-left corner, in the colour the logo
        /// reads on: dark behind a light wordmark, light behind a dark one.
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
            return CGRect(
                x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                width: size.width, height: size.height
            )
        }

        private static func size(of image: CGImage) -> CGSize {
            CGSize(width: image.width, height: image.height)
        }
    }
#endif
