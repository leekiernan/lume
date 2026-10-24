//
//  RingMark.swift
//  Lume
//
//  The two marks built as a core and two rings: Afterglow (a play triangle in
//  two outlines) and Signal (a play wedge with two arcs fanning behind it).
//  Their motions are the same kinds — the rings pulse in turn, rings cast out
//  of the core, the outer ring traces progress, and the launch grows the core
//  in and fades each ring up — differing only in the numbers each logo
//  board gives. `LumeMarkFrame` and `LumeMarkLayer` take those numbers from
//  here, so the two marks share one motion engine. Floodlight's six lights
//  move differently and have their own (`FloodlightMark.swift`).
//

import SwiftUI

nonisolated enum RingMark: Equatable {
    case afterglow, signal

    // MARK: - Resting state

    /// The rings' opacities at rest, and after the launch.
    var rest: (inner: Double, outer: Double) {
        switch self {
        case .afterglow: (0.6, 0.3)
        case .signal: (1, 1)
        }
    }

    /// The outer ring's dim track under Trace and progress.
    var traceTrack: Double {
        switch self {
        case .afterglow: 0.15
        case .signal: 0.18
        }
    }

    // MARK: - Pulse (buffering)

    struct Pulse {
        let low: Double
        let high: Double
        /// Where in the cycle the ring peaks.
        let peak: Double
        let period: TimeInterval
        /// The outer ring's lead on the inner (the board's negative delay).
        let outerLead: TimeInterval

        var stops: [(Double, Double)] {
            [(0, low), (peak, high), (1, low)]
        }
    }

    var pulse: Pulse {
        switch self {
        case .afterglow: Pulse(low: 0.14, high: 0.8, peak: 0.35, period: 1.6, outerLead: 1.3)
        case .signal: Pulse(low: 0.16, high: 1, peak: 0.35, period: 1.4, outerLead: 1.1)
        }
    }

    // MARK: - Cast (going live)

    /// Two copies of a shape grow out from the core and fade, a second apart.
    struct Cast {
        let period: TimeInterval = 2
        let lead: TimeInterval = 1
        let curve = CubicBezier(0.2, 0.6, 0.4, 1)
        let scale: (from: CGFloat, to: CGFloat)
        let opacity: [(Double, Double)]
        /// Drawn width in artboard units, shrinking as the copy grows.
        let lineWidth: (from: CGFloat, to: CGFloat)
    }

    var cast: Cast {
        switch self {
        // Emit: the triangle's outline grows to 2.2× and fades.
        case .afterglow: Cast(scale: (1, 2.2), opacity: [(0, 0.8), (1, 0)], lineWidth: (12, 5.5))
        // Broadcast: the inner arc ripples outwards, appearing as it starts.
        case .signal: Cast(scale: (0.9, 1.45), opacity: [(0, 0), (0.15, 0.9), (1, 0)], lineWidth: (24, 15))
        }
    }

    // MARK: - Geometry

    /// The rings' drawn width, in artboard units.
    var ringWidth: CGFloat {
        switch self {
        case .afterglow: LumeMarkOutline.ringWidth
        case .signal: SignalGeometry.arcWidth
        }
    }

    /// Signal's arcs end round; Afterglow's rings are closed.
    var roundsRingEnds: Bool {
        self == .signal
    }

    /// The core's outline stroke, in artboard units: Signal's wedge is its
    /// sector with a 20-unit rounded edge; Afterglow's triangle is a fill.
    var coreStroke: CGFloat? {
        switch self {
        case .afterglow: nil
        case .signal: SignalGeometry.wedgeStroke
        }
    }

    /// Where the core grows from at launch, in artboard units.
    var coreOrigin: CGPoint {
        switch self {
        case .afterglow: CGPoint(x: 110, y: 120)
        case .signal: SignalGeometry.wedgeOrigin
        }
    }

    /// Where the cast copies grow from, in artboard units.
    var castOrigin: CGPoint {
        switch self {
        case .afterglow: CGPoint(x: 110, y: 120)
        case .signal: SignalGeometry.centre
        }
    }

    func corePath(in rect: CGRect) -> Path {
        switch self {
        case .afterglow: LumeMarkOutline(offset: LumeMarkOutline.triangle).path(in: rect)
        case .signal: SignalGeometry.wedge(in: rect)
        }
    }

    func innerPath(in rect: CGRect) -> Path {
        switch self {
        case .afterglow: LumeMarkOutline(offset: LumeMarkOutline.innerRing).path(in: rect)
        case .signal: SignalGeometry.arc(radius: SignalGeometry.innerRadius, in: rect)
        }
    }

    func outerPath(in rect: CGRect) -> Path {
        switch self {
        case .afterglow: LumeMarkOutline(offset: LumeMarkOutline.outerRing).path(in: rect)
        case .signal: SignalGeometry.arc(radius: SignalGeometry.outerRadius, in: rect)
        }
    }

    /// What Cast grows: Afterglow's triangle outline, Signal's inner arc.
    func castPath(in rect: CGRect) -> Path {
        switch self {
        case .afterglow: corePath(in: rect)
        case .signal: innerPath(in: rect)
        }
    }
}

/// Signal's shapes on the 240-unit artboard: every one centred on the arcs'
/// centre (228, 120), from the board's paths.
nonisolated enum SignalGeometry {
    static let centre = CGPoint(x: 228, y: 120)
    /// The wedge: a sector of radius 106, its point 20 units in from the
    /// centre, spanning ±24.6° about the leftward axis.
    static let wedgeRadius: CGFloat = 106
    static let wedgeTip: CGFloat = 20
    static let wedgeStroke: CGFloat = 20
    /// The board grows the wedge from 70 units left of the centre.
    static let wedgeOrigin = CGPoint(x: 158, y: 120)
    static let innerRadius: CGFloat = 146
    static let outerRadius: CGFloat = 188
    static let arcWidth: CGFloat = 24

    /// A point at `radius` from the centre, `degrees` from the rightward axis
    /// (y down, as the artboard).
    private static func point(_ radius: CGFloat, _ degrees: Double, unit: CGFloat, origin: CGPoint) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: origin.x + (centre.x + radius * cos(radians)) * unit,
                       y: origin.y + (centre.y + radius * sin(radians)) * unit)
    }

    private static func frame(_ rect: CGRect) -> (unit: CGFloat, origin: CGPoint) {
        let unit = min(rect.width, rect.height) / 240
        return (unit, CGPoint(x: rect.midX - 120 * unit, y: rect.midY - 120 * unit))
    }

    /// The half-angle each shape spans, from its endpoints on the board.
    static func halfAngle(radius: CGFloat) -> Double {
        switch radius {
        case wedgeRadius: atan2(44.1, 96.39) * 180 / .pi
        case innerRadius: atan2(62.37, 132.01) * 180 / .pi
        default: atan2(83.42, 168.49) * 180 / .pi
        }
    }

    static func wedge(in rect: CGRect) -> Path {
        let (unit, origin) = frame(rect)
        let half = halfAngle(radius: wedgeRadius)
        var path = Path()
        path.move(to: point(wedgeTip, 180, unit: unit, origin: origin))
        path.addLine(to: point(wedgeRadius, 180 + half, unit: unit, origin: origin))
        path.addArc(center: point(0, 0, unit: unit, origin: origin), radius: wedgeRadius * unit,
                    startAngle: .degrees(180 + half), endAngle: .degrees(180 - half), clockwise: true)
        path.closeSubpath()
        return path
    }

    /// An open arc of `radius`, top end first, as the board draws it (Trace
    /// fills it from the top).
    static func arc(radius: CGFloat, in rect: CGRect) -> Path {
        let (unit, origin) = frame(rect)
        let half = halfAngle(radius: radius)
        var path = Path()
        path.addArc(center: point(0, 0, unit: unit, origin: origin), radius: radius * unit,
                    startAngle: .degrees(180 + half), endAngle: .degrees(180 - half), clockwise: true)
        return path
    }
}
