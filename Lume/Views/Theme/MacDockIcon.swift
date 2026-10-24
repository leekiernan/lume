//
//  MacDockIcon.swift
//  Lume
//
//  The Mac's Dock icon in a colour theme and logo, from the logo's artwork
//  (`LogoDesign`): macOS has no alternate app icons, so while lume runs the
//  Dock shows this, and Finder keeps the bundle's pink Afterglow. Flat, without the Icon Composer icon's glass: the
//  system renders that only for a bundled icon.
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
        static func image(for choice: LumeIconChoice) -> NSImage? {
            let bright = Color.lumeRGB(choice.theme.hex.bright)
            let icon = ZStack {
                RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                    .fill(Color.lumeRGB(0x14101F))
                    .frame(width: tile, height: tile)
                choice.logo.design.artwork(in: bright)
                    .frame(width: mark, height: mark)
            }
            .frame(width: canvas, height: canvas)
            let renderer = ImageRenderer(content: icon)
            renderer.scale = 1
            return renderer.nsImage
        }
    }
#endif
