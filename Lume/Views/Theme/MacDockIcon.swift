//
//  MacDockIcon.swift
//  Lume
//
//  The Mac's Dock icon in a colour theme and logo, drawn from the marks'
//  geometry (`RingMark`, `FloodlightGeometry`): macOS has no alternate
//  app icons, so while lume runs the Dock shows this, and Finder keeps the
//  bundle's pink Afterglow. Flat, without the Icon Composer icon's glass: the
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
                Group {
                    switch choice.logo {
                    case .afterglow: afterglow(bright)
                    case .signal: signal(bright)
                    case .floodlight: floodlight(bright)
                    }
                }
                .frame(width: mark, height: mark)
            }
            .frame(width: canvas, height: canvas)
            let renderer = ImageRenderer(content: icon)
            renderer.scale = 1
            return renderer.nsImage
        }

        private static func afterglow(_ bright: Color) -> some View {
            ZStack {
                LumeMarkOutline(offset: LumeMarkOutline.outerRing, lineWidth: LumeMarkOutline.ringWidth)
                    .fill(bright.opacity(0.3))
                LumeMarkOutline(offset: LumeMarkOutline.innerRing, lineWidth: LumeMarkOutline.ringWidth)
                    .fill(bright.opacity(0.6))
                LumeMarkOutline(offset: LumeMarkOutline.triangle)
                    .fill(bright)
            }
        }

        private static func signal(_ bright: Color) -> some View {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                let unit = min(size.width, size.height) / 240
                let wedge = RingMark.signal.corePath(in: rect)
                context.fill(wedge, with: .color(bright))
                context.stroke(wedge, with: .color(bright), style: StrokeStyle(lineWidth: SignalGeometry.wedgeStroke * unit, lineJoin: .round))
                for arc in [RingMark.signal.innerPath(in: rect), RingMark.signal.outerPath(in: rect)] {
                    context.stroke(arc, with: .color(bright), style: StrokeStyle(lineWidth: SignalGeometry.arcWidth * unit, lineCap: .round))
                }
            }
        }

        private static func floodlight(_ bright: Color) -> some View {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                for light in FloodlightGeometry.lights {
                    context.fill(Path(ellipseIn: FloodlightGeometry.circle(light, in: rect)), with: .color(bright))
                }
            }
        }
    }
#endif
