//
//  LumeMarkLayer.swift
//  Lume
//
//  The mark's motions as Core Animation, not per-frame SwiftUI. The render
//  server runs them, so a loader keeps moving while the main thread is busy —
//  which is exactly when loaders show (a stream opening, a catalog import) —
//  and a screen of them costs no body evaluations. Timings match
//  `LumeMarkFrame` (the brand board's keyframes).
//

import QuartzCore
import SwiftUI

/// What the host view drives, whichever logo draws the mark.
protocol LumeMarkAnimating: CALayer {
    var motion: LumeMark.Motion { get set }
    var reduceMotion: Bool { get set }
    var color: CGColor { get set }
    func resumeIfNeeded()
}

/// A ring mark — Afterglow or Signal (`RingMark`) — on Core Animation.
final class LumeMarkLayer: CALayer, LumeMarkAnimating {
    let mark: RingMark

    var motion: LumeMark.Motion = .still {
        didSet { if motion != oldValue { applyMotion(from: oldValue) } }
    }

    var reduceMotion = false {
        didSet { if reduceMotion != oldValue { applyMotion(from: motion) } }
    }

    var color: CGColor = .init(srgbRed: 1, green: 0.533, blue: 0.843, alpha: 1) {
        didSet { if color != oldValue { applyColor() } }
    }

    private let core = CAShapeLayer()
    private let inner = CAShapeLayer()
    private let outer = CAShapeLayer()
    private let trace = CAShapeLayer()
    private let emits = [CAShapeLayer(), CAShapeLayer()]
    private var laidOutBounds: CGRect = .null

    init(mark: RingMark = .afterglow) {
        self.mark = mark
        super.init()
        for layer in [outer, trace, inner] + emits {
            layer.fillColor = nil
            layer.lineCap = mark.roundsRingEnds ? .round : .butt
            addSublayer(layer)
        }
        addSublayer(core)
        trace.lineCap = .round
        core.lineJoin = .round
        applyColor()
        applyMotion(from: .still)
    }

    /// Core Animation's own `init`, should anything call it: Afterglow.
    override convenience init() {
        self.init(mark: .afterglow)
    }

    override init(layer: Any) {
        mark = (layer as? LumeMarkLayer)?.mark ?? .afterglow
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
        let unit = min(bounds.width, bounds.height) / 240
        /// An artboard point in this layer's bounds.
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: bounds.midX + (point.x - 120) * unit, y: bounds.midY + (point.y - 120) * unit)
        }
        // The core grows in about its origin at launch.
        pin(core, at: place(mark.coreOrigin))
        core.path = mark.corePath(in: core.bounds).cgPath
        core.lineWidth = (mark.coreStroke ?? 0) * unit
        for (layer, path) in [(inner, mark.innerPath(in: bounds)), (outer, mark.outerPath(in: bounds)),
                              (trace, mark.outerPath(in: bounds))]
        {
            layer.frame = bounds
            layer.path = path.cgPath
            layer.lineWidth = mark.ringWidth * unit
        }
        // Cast copies scale about their origin.
        for layer in emits {
            pin(layer, at: place(mark.castOrigin))
            layer.path = mark.castPath(in: layer.bounds).cgPath
            layer.lineWidth = mark.ringWidth * unit
        }
        CATransaction.commit()
        // Line widths are animated in points; restart against the new size.
        if case .emit = motion { applyMotion(from: motion) }
    }

    /// Fills the bounds, scaling about `point`.
    private func pin(_ layer: CALayer, at point: CGPoint) {
        layer.bounds = CGRect(origin: .zero, size: bounds.size)
        layer.anchorPoint = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        layer.position = point
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        core.fillColor = color
        core.strokeColor = mark.coreStroke == nil ? nil : color
        for layer in [inner, outer, trace] + emits {
            layer.strokeColor = color
        }
        CATransaction.commit()
    }

    /// Restarts the motion only if the system dropped its animations (e.g.
    /// the app went to the background). Re-parenting alone keeps them —
    /// restarting there froze the mark on its first keyframe in views that
    /// rebuild often, like the player's overlays.
    func resumeIfNeeded() {
        let animated = !motion.isStatic && !reduceMotion
        let running = ([inner, outer, trace] + emits).contains { !($0.animationKeys() ?? []).isEmpty }
        if animated, !running { applyMotion(from: motion) }
    }

    /// Re-applies the current motion: after a change, or a size change.
    func applyMotion(from previous: LumeMark.Motion) {
        let effective: LumeMark.Motion = reduceMotion && !motion.isStatic ? .still : motion
        rest(at: effective)
        switch effective {
        case .still: break
        case let .progress(fraction): fill(to: fraction, from: previous)
        case .pulse: startPulse()
        case .emit: startEmit()
        case .trace: startTrace()
        case .launch: startLaunch()
        }
    }

    /// The motion's resting layer values, with every running animation gone.
    private func rest(at motion: LumeMark.Motion) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [core, inner, outer, trace] + emits {
            layer.removeAllAnimations()
        }
        // Finite animations disappear on completion; the model must already
        // contain their final values, rather than the invisible opening frame.
        let frame = LumeMarkFrame(motion: motion, elapsed: motion == .launch ? LumeMarkFrame.launchDuration : 0, mark: mark)
        core.opacity = 1
        inner.opacity = Float(frame.inner)
        outer.opacity = Float(frame.outer)
        trace.opacity = frame.trace == nil ? 0 : 1
        trace.strokeEnd = frame.trace ?? 0
        for layer in emits {
            layer.opacity = 0
        }
        CATransaction.commit()
    }

    /// Fills from where it was, as a sync advances.
    private func fill(to _: Double, from previous: LumeMark.Motion) {
        if case let .progress(old) = previous {
            let fill = CABasicAnimation(keyPath: "strokeEnd")
            fill.fromValue = CGFloat(min(max(old, 0), 1))
            fill.duration = 0.4
            fill.timingFunction = CAMediaTimingFunction(name: .easeOut)
            trace.add(fill, forKey: "fill")
        }
    }

    private func startPulse() {
        let spec = mark.pulse
        let pulse = keyframes("opacity", values: spec.stops.map(\.1), times: spec.stops.map(\.0), duration: spec.period)
        inner.opacity = Float(spec.low)
        outer.opacity = Float(spec.low)
        pulse.timeOffset = Self.phase(spec.period)
        inner.add(pulse, forKey: "pulse")
        // The outer ring runs ahead (the board's negative delay).
        pulse.timeOffset += spec.outerLead
        outer.add(pulse, forKey: "pulse")
    }

    private func startEmit() {
        let unit = min(bounds.width, bounds.height) / 240
        let cast = mark.cast
        let curve = CAMediaTimingFunction(controlPoints: Float(cast.curve.first.x), Float(cast.curve.first.y),
                                          Float(cast.curve.second.x), Float(cast.curve.second.y))
        func eased(_ keyPath: String, _ stops: [(Double, Double)]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = stops.map(\.1)
            animation.keyTimes = stops.map { NSNumber(value: $0.0) }
            animation.timingFunctions = Array(repeating: curve, count: stops.count - 1)
            return animation
        }
        for (index, layer) in emits.enumerated() {
            let group = CAAnimationGroup()
            group.animations = [
                eased("transform.scale", [(0, cast.scale.from), (1, cast.scale.to)]),
                eased("opacity", cast.opacity),
                // Drawn width shrinks as the copy grows, as on the board.
                eased("lineWidth", [(0, cast.lineWidth.from * unit), (1, cast.lineWidth.to * unit)])
            ]
            group.duration = cast.period
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            group.timeOffset = Self.phase(cast.period) + Double(index) * cast.lead
            layer.add(group, forKey: "emit")
        }
    }

    private func startTrace() {
        let draw = keyframes("strokeEnd", values: [0, 1, 1], times: [0, 0.7, 1], duration: LumeMarkFrame.tracePeriod)
        let fade = keyframes("opacity", values: [1, 1, 0], times: [0, 0.86, 1], duration: LumeMarkFrame.tracePeriod)
        draw.timeOffset = Self.phase(LumeMarkFrame.tracePeriod)
        fade.timeOffset = draw.timeOffset
        trace.add(draw, forKey: "draw")
        trace.add(fade, forKey: "fade")
    }

    /// Once, from nothing (`LumeMarkFrame`'s launch): the core grows in, then
    /// each ring fades up to rest.
    private func startLaunch() {
        let grow = CAAnimationGroup()
        let coreEnd = LumeMarkFrame.coreWindow.end
        grow.animations = [
            keyframes("opacity", values: [0, 1], times: [0, 1], duration: coreEnd, repeats: false, timing: .easeOut),
            keyframes("transform.scale", values: [0.6, 1], times: [0, 1], duration: coreEnd, repeats: false, timing: .easeOut)
        ]
        grow.duration = coreEnd
        core.add(grow, forKey: "launch")
        for (layer, window, rest) in [(inner, LumeMarkFrame.innerWindow, mark.rest.inner), (outer, LumeMarkFrame.outerWindow, mark.rest.outer)] {
            let fade = keyframes("opacity", values: [0, 0, rest], times: [0, window.start / window.end, 1],
                                 duration: window.end, repeats: false, timing: .easeOut)
            layer.add(fade, forKey: "launch")
        }
    }

    /// Loops run on the shared media clock rather than from when they were
    /// added: a host SwiftUI rebuilds continues mid-cycle instead of
    /// restarting, and every loader on screen moves in step.
    private static func phase(_ period: TimeInterval) -> TimeInterval {
        CACurrentMediaTime().truncatingRemainder(dividingBy: period)
    }

    private func keyframes(
        _ keyPath: String, values: [Double], times: [Double], duration: TimeInterval, repeats: Bool = true,
        timing: CAMediaTimingFunctionName = .easeInEaseOut
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0) }
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: timing), count: max(values.count - 1, 1))
        animation.duration = duration
        animation.repeatCount = repeats ? .infinity : 0
        animation.isRemovedOnCompletion = !repeats
        return animation
    }
}

extension LumeLogo {
    func makeMarkLayer() -> CALayer & LumeMarkAnimating {
        design.makeMarkLayer()
    }
}

/// The host views' shared part: the mark layer for the logo, replaced when
/// the logo changes, with the state the host last gave it.
struct LumeMarkUpdate {
    let motion: LumeMark.Motion
    let color: CGColor
    let logo: LumeLogo
    let reduceMotion: Bool

    /// Applies itself to `host`'s mark, first swapping in a layer for a new
    /// logo; returns the layer now in place.
    @discardableResult
    func apply(
        to mark: CALayer & LumeMarkAnimating, currentLogo: LumeLogo, replace: (CALayer & LumeMarkAnimating) -> Void
    ) -> CALayer & LumeMarkAnimating {
        var target = mark
        if logo != currentLogo {
            target = logo.makeMarkLayer()
            target.frame = mark.frame
            replace(target)
        }
        target.color = color
        target.reduceMotion = reduceMotion
        target.motion = motion
        return target
    }
}

#if os(macOS)
    import AppKit

    struct LumeMarkLayerView: NSViewRepresentable {
        let motion: LumeMark.Motion
        let color: Color
        let logo: LumeLogo

        func makeNSView(context _: Context) -> LumeMarkHostView {
            LumeMarkHostView(logo: logo)
        }

        func updateNSView(_ view: LumeMarkHostView, context: Context) {
            view.update(LumeMarkUpdate(
                motion: motion, color: color.resolve(in: context.environment).cgColor, logo: logo,
                reduceMotion: context.environment.accessibilityReduceMotion
            ))
        }
    }

    final class LumeMarkHostView: NSView {
        private(set) var mark: CALayer & LumeMarkAnimating
        private var logo: LumeLogo

        init(logo: LumeLogo) {
            self.logo = logo
            mark = logo.makeMarkLayer()
            super.init(frame: .zero)
            wantsLayer = true
            layer?.isGeometryFlipped = true
            layer?.addSublayer(mark)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(_ update: LumeMarkUpdate) {
            mark = update.apply(to: mark, currentLogo: logo) { layer?.replaceSublayer(mark, with: $0) }
            logo = update.logo
        }

        override func layout() {
            super.layout()
            mark.frame = bounds
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { mark.resumeIfNeeded() }
        }
    }
#else
    import UIKit

    struct LumeMarkLayerView: UIViewRepresentable {
        let motion: LumeMark.Motion
        let color: Color
        let logo: LumeLogo

        func makeUIView(context _: Context) -> LumeMarkHostView {
            LumeMarkHostView(logo: logo)
        }

        func updateUIView(_ view: LumeMarkHostView, context: Context) {
            view.update(LumeMarkUpdate(
                motion: motion, color: color.resolve(in: context.environment).cgColor, logo: logo,
                reduceMotion: context.environment.accessibilityReduceMotion
            ))
        }
    }

    final class LumeMarkHostView: UIView {
        private(set) var mark: CALayer & LumeMarkAnimating
        private var logo: LumeLogo

        init(logo: LumeLogo) {
            self.logo = logo
            mark = logo.makeMarkLayer()
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            layer.addSublayer(mark)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(_ update: LumeMarkUpdate) {
            mark = update.apply(to: mark, currentLogo: logo) { layer.replaceSublayer(mark, with: $0) }
            logo = update.logo
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            mark.frame = bounds
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { mark.resumeIfNeeded() }
        }
    }
#endif
