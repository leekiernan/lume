//
//  MacDockIcon.swift
//  Lume
//
//  The Mac's Dock icon in a colour theme, drawn from the mark's geometry
//  (`LumeMarkOutline`): macOS has no alternate app icons, so while lume runs
//  the Dock shows this, and Finder keeps the bundle's pink icon. Flat, without
//  the Icon Composer icon's glass: the system renders that only for a bundled
//  icon.
//

#if os(macOS)
    import AppKit
    import SwiftUI

    enum MacDockIcon {
        /// The full canvas, the squircle macOS draws icons in, and the mark
        /// inside it — the Icon Composer layers' 3× scale of the 240-unit mark.
        private static let canvas: CGFloat = 1024
        private static let tile: CGFloat = 824
        private static let mark: CGFloat = tile * 720 / 1024

        @MainActor
        static func image(for theme: LumeColorTheme) -> NSImage? {
            let bright = Color.lumeRGB(theme.hex.bright)
            let icon = ZStack {
                RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                    .fill(Color.lumeRGB(0x14101F))
                    .frame(width: tile, height: tile)
                ZStack {
                    LumeMarkOutline(offset: LumeMarkOutline.outerRing, lineWidth: LumeMarkOutline.ringWidth)
                        .fill(bright.opacity(0.3))
                    LumeMarkOutline(offset: LumeMarkOutline.innerRing, lineWidth: LumeMarkOutline.ringWidth)
                        .fill(bright.opacity(0.6))
                    LumeMarkOutline(offset: LumeMarkOutline.triangle)
                        .fill(bright)
                }
                .frame(width: mark, height: mark)
            }
            .frame(width: canvas, height: canvas)
            let renderer = ImageRenderer(content: icon)
            renderer.scale = 1
            return renderer.nsImage
        }
    }
#endif
