//
//  LogoDesign.swift
//  Lume
//
//  Everything the app knows about one logo, in one place: its name, the
//  Core Animation layer that draws and animates it, its launch timings, its
//  alternate icons' names and its artwork for the Mac's Dock. `LumeLogo.design`
//  is the one switch over the logos; every surface asks the design, so a new
//  logo is a new design here and its icon artwork in
//  `Scripts/generate-icon-colourways.py`.
//

import QuartzCore
import SwiftUI

nonisolated protocol LogoDesign {
    /// The design's name for the mark, shown in Settings as it is.
    var title: String { get }
    /// The start of its alternate icons' names, before the colour ("Lume",
    /// "LumeSignal"): see `LumeIconChoice.iconName`.
    var iconPrefix: String { get }
    var launch: LogoLaunch { get }
    /// The layer `LumeMark` draws it with, for every motion.
    @MainActor func makeMarkLayer() -> CALayer & LumeMarkAnimating
    /// The mark at rest in `bright`, filling its frame: the Mac's Dock icon.
    @MainActor func artwork(in bright: Color) -> AnyView
}

/// When a logo's launch brings the wordmark in, and when the mark rests.
nonisolated struct LogoLaunch {
    let wordmark: (start: Double, end: Double)
    let duration: Double
}

extension LumeLogo {
    /// The one place a logo is turned into its design.
    nonisolated var design: any LogoDesign {
        switch self {
        case .afterglow: RingLogoDesign(mark: .afterglow, title: "Afterglow", iconPrefix: "Lume")
        case .signal: RingLogoDesign(mark: .signal, title: "Signal", iconPrefix: "LumeSignal")
        case .floodlight: FloodlightDesign()
        }
    }
}

/// Afterglow and Signal: a core and two rings, described by a `RingMark` and
/// animated by `LumeMarkLayer`. Both boards launch on the same windows.
nonisolated struct RingLogoDesign: LogoDesign {
    let mark: RingMark
    let title: String
    let iconPrefix: String

    var launch: LogoLaunch {
        LogoLaunch(wordmark: LumeMarkFrame.wordmarkWindow, duration: LumeMarkFrame.launchDuration)
    }

    @MainActor func makeMarkLayer() -> CALayer & LumeMarkAnimating {
        LumeMarkLayer(mark: mark)
    }

    @MainActor func artwork(in bright: Color) -> AnyView {
        let mark = mark
        return AnyView(Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let unit = min(size.width, size.height) / 240
            let ring = StrokeStyle(lineWidth: mark.ringWidth * unit, lineCap: mark.roundsRingEnds ? .round : .butt)
            context.stroke(mark.outerPath(in: rect), with: .color(bright.opacity(mark.rest.outer)), style: ring)
            context.stroke(mark.innerPath(in: rect), with: .color(bright.opacity(mark.rest.inner)), style: ring)
            let core = mark.corePath(in: rect)
            context.fill(core, with: .color(bright))
            if let stroke = mark.coreStroke {
                context.stroke(core, with: .color(bright), style: StrokeStyle(lineWidth: stroke * unit, lineJoin: .round))
            }
        })
    }
}

/// Floodlight: six lights, animated by `FloodlightMarkLayer`.
nonisolated struct FloodlightDesign: LogoDesign {
    let title = "Floodlight"
    let iconPrefix = "LumeFloodlight"

    var launch: LogoLaunch {
        LogoLaunch(wordmark: FloodlightFrame.wordmarkWindow, duration: FloodlightFrame.launchDuration)
    }

    @MainActor func makeMarkLayer() -> CALayer & LumeMarkAnimating {
        FloodlightMarkLayer()
    }

    @MainActor func artwork(in bright: Color) -> AnyView {
        AnyView(Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            for light in FloodlightGeometry.lights {
                context.fill(Path(ellipseIn: FloodlightGeometry.circle(light, in: rect)), with: .color(bright))
            }
        })
    }
}
