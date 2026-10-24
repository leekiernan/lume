import CoreGraphics
@testable import Lume
import QuartzCore
import Testing

struct FloodlightMarkTests {
    @Test func `the lights sit where the board draws them`() {
        let rect = CGRect(x: 0, y: 0, width: 240, height: 240)
        let centres = FloodlightGeometry.lights.map { FloodlightGeometry.circle($0, in: rect) }.map { CGPoint(x: $0.midX, y: $0.midY) }
        #expect(centres.first == CGPoint(x: 59.65, y: 48))
        #expect(centres.last == CGPoint(x: 184.35, y: 120))
        #expect(FloodlightGeometry.circle(FloodlightGeometry.lights[0], in: rect).width == 54)
        // Scaled to a smaller box, about its centre.
        let half = FloodlightGeometry.circle(FloodlightGeometry.lights[5], in: CGRect(x: 0, y: 0, width: 120, height: 120))
        #expect(abs(half.midX - 92.175) < 1e-6 && abs(half.width - 27) < 1e-6)
    }

    @Test func `sweep brightens the columns in turn towards the tip`() {
        func peak(column: Int) -> Double {
            let index = FloodlightGeometry.lights.firstIndex { $0.column == column } ?? 0
            let samples = stride(from: 0.0, to: FloodlightFrame.sweepPeriod, by: 0.01)
            return samples.max { FloodlightFrame(motion: .pulse, elapsed: $0).opacities[index]
                < FloodlightFrame(motion: .pulse, elapsed: $1).opacities[index]
            } ?? 0
        }
        let (back, middle, tip) = (peak(column: 0), peak(column: 1), peak(column: 2))
        #expect(abs(middle - back - 0.2) < 0.02)
        #expect(abs(tip - middle - 0.2) < 0.02)
    }

    @Test func `orbit runs one bright light round the edge`() {
        let start = FloodlightFrame(motion: .emit, elapsed: 0).opacities
        #expect(start[0] == 1)
        #expect(start.count(where: { $0 == 1 }) == 1)
        // A step later the next light round the edge — the middle column's top — is lit.
        let next = FloodlightFrame(motion: .emit, elapsed: FloodlightFrame.orbitStep).opacities
        #expect(next[3] == 1)
    }

    @Test func `fill switches the lights on in order and all off together`() {
        let early = FloodlightFrame(motion: .trace, elapsed: 0.1 * FloodlightFrame.fillPeriod).opacities
        #expect(early[0] == 1 && early[5] == FloodlightFrame.unlit)
        let full = FloodlightFrame(motion: .trace, elapsed: 0.85 * FloodlightFrame.fillPeriod).opacities
        #expect(full.allSatisfy { $0 == 1 })
        let off = FloodlightFrame(motion: .trace, elapsed: 0.97 * FloodlightFrame.fillPeriod).opacities
        #expect(off.allSatisfy { abs($0 - FloodlightFrame.unlit) < 1e-9 })
    }

    @Test func `progress lights its share, the next one partly`() {
        let half = FloodlightFrame(motion: .progress(0.5), elapsed: 0).opacities
        #expect(half[0 ..< 3].allSatisfy { $0 == 1 })
        #expect(half[3 ..< 6].allSatisfy { $0 == FloodlightFrame.unlit })
        let between = FloodlightFrame(motion: .progress(0.25), elapsed: 0).opacities
        #expect(between[1] > FloodlightFrame.unlit && between[1] < 1)
    }

    @Test func `launch switches the columns on in turn from nothing`() {
        let first = FloodlightFrame(motion: .launch, elapsed: 0)
        #expect(first.opacities.allSatisfy { $0 == 0 })
        #expect(first.wordmark == 0)
        let backOn = FloodlightFrame(motion: .launch, elapsed: FloodlightFrame.launchWindow(column: 0).end)
        #expect(backOn.opacities[0] == 1 && backOn.opacities[5] == 0)
        let rested = FloodlightFrame(motion: .launch, elapsed: 30)
        #expect(rested == FloodlightFrame(motion: .still, elapsed: 0))
    }
}

@MainActor
struct FloodlightMarkLayerTests {
    private func layer(_ motion: LumeMark.Motion, reduceMotion: Bool = false) -> FloodlightMarkLayer {
        let mark = FloodlightMarkLayer()
        mark.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        mark.layoutIfNeeded()
        mark.reduceMotion = reduceMotion
        mark.motion = motion
        return mark
    }

    private func keys(_ mark: FloodlightMarkLayer) -> Set<String> {
        Set((mark.sublayers ?? []).flatMap { $0.animationKeys() ?? [] })
    }

    @Test func `each motion runs on Core Animation`() {
        #expect(keys(layer(.still)).isEmpty)
        #expect(keys(layer(.pulse)) == ["sweep"])
        #expect(keys(layer(.emit)) == ["orbit"])
        #expect(keys(layer(.trace)) == ["fill"])
        #expect(keys(layer(.launch)) == ["launch"])
    }

    @Test func `reduce motion rests the lights but keeps progress`() {
        #expect(keys(layer(.pulse, reduceMotion: true)).isEmpty)
        let progress = layer(.progress(0.5), reduceMotion: true)
        let opacities = (progress.sublayers ?? []).map(\.opacity)
        #expect(opacities.count(where: { $0 == 1 }) == 3)
    }
}
