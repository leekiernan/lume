//
//  FloodlightMark.swift
//  Lume
//
//  The Floodlight mark — six round lights arranged as a play triangle — and
//  its motions, from the logo board's Floodlight boards (a 240-unit artboard,
//  CSS keyframes). Each of Afterglow's motions has its Floodlight form:
//
//  - pulse (buffering) → Sweep: the columns brighten in turn towards the tip;
//  - emit (going live) → Orbit: one bright light runs round the triangle;
//  - trace (progress) → Fill: the lights switch on one at a time, and fade;
//  - progress(fraction) → that share of the lights on, the next one partly;
//  - launch → the columns switch on in turn, growing in.
//
//  `FloodlightFrame` is the specification, a pure function of time;
//  `FloodlightMarkLayer` runs it on Core Animation, like `LumeMarkLayer`.
//

import QuartzCore
import SwiftUI

nonisolated enum FloodlightGeometry {
    struct Light {
        let center: CGPoint
        /// 0 the back column, 1 the middle, 2 the tip.
        let column: Int
        /// Its turn in Orbit, which runs round the triangle's edge.
        let orbitTurn: Int
    }

    static let radius: CGFloat = 27

    /// In Fill's order — the board's f1…f6: the back column top to bottom,
    /// then the middle, then the tip.
    static let lights: [Light] = [
        Light(center: CGPoint(x: 59.65, y: 48), column: 0, orbitTurn: 0),
        Light(center: CGPoint(x: 59.65, y: 120), column: 0, orbitTurn: 5),
        Light(center: CGPoint(x: 59.65, y: 192), column: 0, orbitTurn: 4),
        Light(center: CGPoint(x: 122, y: 84), column: 1, orbitTurn: 1),
        Light(center: CGPoint(x: 122, y: 156), column: 1, orbitTurn: 3),
        Light(center: CGPoint(x: 184.35, y: 120), column: 2, orbitTurn: 2)
    ]

    /// A light's circle in `rect`, the 240-unit artboard scaled to fit.
    static func circle(_ light: Light, in rect: CGRect) -> CGRect {
        let unit = min(rect.width, rect.height) / 240
        let origin = CGPoint(x: rect.midX - 120 * unit, y: rect.midY - 120 * unit)
        let radius = radius * unit
        return CGRect(x: origin.x + light.center.x * unit - radius, y: origin.y + light.center.y * unit - radius,
                      width: radius * 2, height: radius * 2)
    }
}

/// The lights' state at a moment of a motion.
nonisolated struct FloodlightFrame: Equatable {
    var opacities = Array(repeating: 1.0, count: 6)
    var scales = Array(repeating: 1.0, count: 6)
    /// The wordmark's arrival during `.launch` (opacity, and rise in points).
    var wordmark = 1.0
    var wordmarkRise: CGFloat = 0

    static let sweepPeriod = 1.3
    static let orbitPeriod = 1.2
    static let fillPeriod = 3.2
    /// The board's launch cycle; it holds at rest after 84% of it.
    static let launchCycle = 3.6
    /// When the launch has finished and the mark rests.
    static let launchDuration = 1.5
    /// The dim level of an unlit light in Fill and progress.
    static let unlit = 0.18

    /// Sweep: each column's lead on the back column (the board's delays).
    static let sweepLead = [0.0, 1.1, 0.9]
    /// Orbit: each turn comes this long after the one before.
    static let orbitStep = 0.2

    init(motion: LumeMark.Motion, elapsed: TimeInterval) {
        let lights = FloodlightGeometry.lights
        switch motion {
        case .still:
            break
        case .pulse:
            let sweep = Keyframes([(0, 0.2), (0.28, 1), (0.6, 0.2), (1, 0.2)], easing: .easeInOut)
            opacities = lights.map { sweep.value(at: Self.phase(elapsed + Self.sweepLead[$0.column], Self.sweepPeriod)) }
        case .emit:
            let orbit = Keyframes([(0, 1), (0.7, 0.16), (1, 0.16)], easing: .linear)
            opacities = lights.map {
                orbit.value(at: Self.phase(elapsed - Self.orbitStep * Double($0.orbitTurn), Self.orbitPeriod))
            }
        case .trace:
            let phase = Self.phase(elapsed, Self.fillPeriod)
            opacities = lights.indices.map { Self.fill(light: $0).value(at: phase) }
        case let .progress(fraction):
            let lit = min(max(fraction, 0), 1) * Double(lights.count)
            opacities = lights.indices.map { Self.unlit + (1 - Self.unlit) * min(max(lit - Double($0), 0), 1) }
        case .launch:
            let seconds = min(elapsed, Self.launchDuration)
            for (index, light) in lights.enumerated() {
                let (start, end) = Self.launchWindow(column: light.column)
                let switchOn = Keyframes([(0, 0), (start, 0), (end, 1)], easing: .easeOut)
                    .value(at: seconds / Self.launchCycle, scale: Self.launchCycle)
                opacities[index] = switchOn
                scales[index] = 0.4 + 0.6 * switchOn
            }
            let arrival = Keyframes([(0, 0), (Self.wordmarkWindow.start, 0), (Self.wordmarkWindow.end, 1)], easing: .easeOut)
                .value(at: seconds / Self.launchCycle, scale: Self.launchCycle)
            wordmark = arrival
            wordmarkRise = 14 * (1 - arrival)
        }
    }

    /// When a column switches on in the launch, in seconds: the board's
    /// 0–10%, 8–18% and 16–26% of its cycle.
    static func launchWindow(column: Int) -> (start: Double, end: Double) {
        ((0.08 * Double(column)) * launchCycle, (0.10 + 0.08 * Double(column)) * launchCycle)
    }

    /// The wordmark's arrival, in seconds: the board's 28–40%.
    static let wordmarkWindow = (start: 0.28 * launchCycle, end: 0.40 * launchCycle)

    /// Fill's stops for the light at `index`: off, on in its turn, all
    /// together off again at the end of the cycle.
    static func fill(light index: Int) -> Keyframes {
        let switchOn = 0.02 + 0.12 * Double(index)
        return Keyframes([(0, unlit), (switchOn, unlit), (switchOn + 0.06, 1), (0.88, 1), (0.96, unlit), (1, unlit)], easing: .linear)
    }

    private static func phase(_ elapsed: TimeInterval, _ period: TimeInterval) -> Double {
        let value = elapsed.truncatingRemainder(dividingBy: period) / period
        return value < 0 ? value + 1 : value
    }
}

/// `FloodlightFrame` on Core Animation: six circle layers, each scaled about
/// its own centre.
final class FloodlightMarkLayer: CALayer, LumeMarkAnimating {
    var motion: LumeMark.Motion = .still {
        didSet { if motion != oldValue { applyMotion(from: oldValue) } }
    }

    var reduceMotion = false {
        didSet { if reduceMotion != oldValue { applyMotion(from: motion) } }
    }

    var color: CGColor = .init(srgbRed: 1, green: 0.533, blue: 0.843, alpha: 1) {
        didSet { if color != oldValue { applyColor() } }
    }

    private let lights = FloodlightGeometry.lights.map { _ in CAShapeLayer() }
    private var laidOutBounds: CGRect = .null

    override init() {
        super.init()
        for light in lights {
            addSublayer(light)
        }
        applyColor()
        applyMotion(from: .still)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        guard bounds != laidOutBounds, bounds.width > 0, bounds.height > 0 else { return }
        laidOutBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, light) in zip(lights, FloodlightGeometry.lights) {
            let circle = FloodlightGeometry.circle(light, in: bounds)
            layer.frame = circle
            layer.path = CGPath(ellipseIn: CGRect(origin: .zero, size: circle.size), transform: nil)
        }
        CATransaction.commit()
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for light in lights {
            light.fillColor = color
        }
        CATransaction.commit()
    }

    func resumeIfNeeded() {
        let animated = !motion.isStatic && !reduceMotion
        let running = lights.contains { !($0.animationKeys() ?? []).isEmpty }
        if animated, !running { applyMotion(from: motion) }
    }

    func applyMotion(from previous: LumeMark.Motion) {
        let effective: LumeMark.Motion = reduceMotion && !motion.isStatic ? .still : motion
        rest(at: effective, from: previous)
        switch effective {
        case .still, .progress: break
        case .pulse: startSweep()
        case .emit: startOrbit()
        case .trace: startFill()
        case .launch: startLaunch()
        }
    }

    /// The motion's resting values, with every running animation gone. A
    /// change of progress eases each light to its new level.
    private func rest(at motion: LumeMark.Motion, from previous: LumeMark.Motion) {
        CATransaction.begin()
        let easesProgress = if case .progress = motion, case .progress = previous { true } else { false }
        CATransaction.setDisableActions(!easesProgress)
        CATransaction.setAnimationDuration(0.4)
        let frame = FloodlightFrame(motion: motion.isStatic ? motion : .still, elapsed: 0)
        for (layer, opacity) in zip(lights, frame.opacities) {
            layer.removeAllAnimations()
            layer.opacity = Float(opacity)
            layer.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    private func startSweep() {
        for (layer, light) in zip(lights, FloodlightGeometry.lights) {
            let sweep = keyframes("opacity", [(0, 0.2), (0.28, 1), (0.6, 0.2), (1, 0.2)],
                                  duration: FloodlightFrame.sweepPeriod, timing: .easeInEaseOut)
            sweep.timeOffset = Self.phase(FloodlightFrame.sweepPeriod) + FloodlightFrame.sweepLead[light.column]
            layer.add(sweep, forKey: "sweep")
        }
    }

    private func startOrbit() {
        for (layer, light) in zip(lights, FloodlightGeometry.lights) {
            let orbit = keyframes("opacity", [(0, 1), (0.7, 0.16), (1, 0.16)],
                                  duration: FloodlightFrame.orbitPeriod, timing: .linear)
            let lag = FloodlightFrame.orbitStep * Double(light.orbitTurn)
            orbit.timeOffset = (Self.phase(FloodlightFrame.orbitPeriod) - lag + FloodlightFrame.orbitPeriod)
                .truncatingRemainder(dividingBy: FloodlightFrame.orbitPeriod)
            layer.add(orbit, forKey: "orbit")
        }
    }

    private func startFill() {
        for (index, layer) in lights.enumerated() {
            let stops = FloodlightFrame.fill(light: index).stops.map { ($0.at, $0.value) }
            let fill = keyframes("opacity", stops, duration: FloodlightFrame.fillPeriod, timing: .linear)
            fill.timeOffset = Self.phase(FloodlightFrame.fillPeriod)
            layer.add(fill, forKey: "fill")
        }
    }

    /// Once, from nothing: the columns switch on in turn, growing in.
    private func startLaunch() {
        for (layer, light) in zip(lights, FloodlightGeometry.lights) {
            let (start, end) = FloodlightFrame.launchWindow(column: light.column)
            let delay = start / end
            let group = CAAnimationGroup()
            group.animations = [
                keyframes("opacity", [(0, 0), (delay, 0), (1, 1)], duration: end, timing: .easeOut, repeats: false),
                keyframes("transform.scale", [(0, 0.4), (delay, 0.4), (1, 1)], duration: end, timing: .easeOut, repeats: false)
            ]
            group.duration = end
            layer.add(group, forKey: "launch")
        }
    }

    private static func phase(_ period: TimeInterval) -> TimeInterval {
        CACurrentMediaTime().truncatingRemainder(dividingBy: period)
    }

    /// `stops` are (fraction of `duration`, value), as the board's keyframes.
    private func keyframes(
        _ keyPath: String, _ stops: [(Double, Double)], duration: TimeInterval,
        timing: CAMediaTimingFunctionName, repeats: Bool = true
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = stops.map(\.1)
        animation.keyTimes = stops.map { NSNumber(value: $0.0) }
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: timing), count: max(stops.count - 1, 1))
        animation.duration = duration
        animation.repeatCount = repeats ? .infinity : 0
        return animation
    }
}
