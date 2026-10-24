import CoreGraphics
@testable import Lume
import QuartzCore
import SwiftUI
import Testing

struct SignalMarkTests {
    private let board = CGRect(x: 0, y: 0, width: 240, height: 240)

    /// The board's points are relative to translate(228 120).
    private func boardPoint(_ offset: CGPoint) -> CGPoint {
        CGPoint(x: 228 + offset.x, y: 120 + offset.y)
    }

    private func near(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y) < 0.05
    }

    @Test func `the arcs run the short way between the board's endpoints`() {
        for (radius, end) in [(SignalGeometry.innerRadius, CGPoint(x: -132.01, y: 62.37)),
                              (SignalGeometry.outerRadius, CGPoint(x: -168.49, y: 83.42))]
        {
            let path = SignalGeometry.arc(radius: radius, in: board)
            let bounds = path.boundingRect
            // Top end first, as the board draws it (Trace fills from the top).
            #expect(near(path.cgPath.currentPoint, boardPoint(end)))
            #expect(abs(bounds.minY - (120 - end.y)) < 0.05 && abs(bounds.maxY - (120 + end.y)) < 0.05)
            // The short way: the arc stays left of its endpoints, round through
            // the leftmost point, never round the far side.
            #expect(abs(bounds.minX - (228 - radius)) < 0.05)
            #expect(bounds.maxX < 228 + end.x + 0.05)
        }
    }

    @Test func `the wedge is the board's sector, its point towards the arcs' centre`() {
        let bounds = SignalGeometry.wedge(in: board).boundingRect
        #expect(abs(bounds.minX - (228 - 106)) < 0.05)
        #expect(abs(bounds.maxX - (228 - 20)) < 0.05)
        #expect(abs(bounds.minY - (120 - 44.1)) < 0.05 && abs(bounds.maxY - (120 + 44.1)) < 0.05)
    }

    @Test func `signal rests fully lit and pulses to full`() {
        let still = LumeMarkFrame(motion: .still, elapsed: 0, mark: .signal)
        #expect(still.inner == 1 && still.outer == 1)
        let peak = LumeMarkFrame(motion: .pulse, elapsed: 0.35 * 1.4, mark: .signal)
        #expect(abs(peak.inner - 1) < 1e-6)
        #expect(LumeMarkFrame(motion: .trace, elapsed: 0, mark: .signal).outer == 0.18)
    }

    @Test func `broadcast arcs appear, grow and fade`() {
        let start = LumeMarkFrame(motion: .emit, elapsed: 0, mark: .signal).emits[0]
        #expect(start.opacity == 0 && abs(start.scale - 0.9) < 1e-6 && start.lineWidth == 24)
        let shown = LumeMarkFrame(motion: .emit, elapsed: 0.15 * 2, mark: .signal).emits[0]
        #expect(abs(shown.opacity - 0.9) < 1e-6)
        let late = LumeMarkFrame(motion: .emit, elapsed: 1.98, mark: .signal).emits[0]
        #expect(late.opacity < 0.05 && late.scale > 1.4)
    }

    @Test func `launch grows the wedge then lights the arcs, and rests lit`() {
        let first = LumeMarkFrame(motion: .launch, elapsed: 0, mark: .signal)
        #expect(first.core == 0 && first.inner == 0 && first.outer == 0)
        let rested = LumeMarkFrame(motion: .launch, elapsed: 30, mark: .signal)
        #expect(rested == LumeMarkFrame(motion: .still, elapsed: 0, mark: .signal))
    }

    @Test func `afterglow keeps its own numbers`() {
        let still = LumeMarkFrame(motion: .still, elapsed: 0)
        #expect(still.inner == 0.6 && still.outer == 0.3)
        #expect(LumeMarkFrame(motion: .emit, elapsed: 0).emits[0].opacity == 0.8)
    }
}

@MainActor
struct SignalMarkLayerTests {
    @Test func `each motion runs on Core Animation`() {
        func keys(_ motion: LumeMark.Motion) -> [String] {
            let mark = LumeMarkLayer(mark: .signal)
            mark.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
            mark.layoutIfNeeded()
            mark.motion = motion
            return (mark.sublayers ?? []).flatMap { $0.animationKeys() ?? [] }.sorted()
        }
        #expect(keys(.pulse) == ["pulse", "pulse"])
        #expect(keys(.emit) == ["emit", "emit"])
        #expect(keys(.trace) == ["draw", "fade"])
        #expect(keys(.launch) == ["launch", "launch", "launch"])
    }

    @Test func `the wedge carries its rounded outline and the arcs round ends`() {
        let mark = LumeMarkLayer(mark: .signal)
        mark.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        mark.layoutIfNeeded()
        let shapes = (mark.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        #expect(shapes.contains { $0.fillColor != nil && $0.strokeColor != nil && $0.lineWidth == 20 })
        #expect(shapes.filter { $0.fillColor == nil }.allSatisfy { $0.lineCap == .round })
    }
}
