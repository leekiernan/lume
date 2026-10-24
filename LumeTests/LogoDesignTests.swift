import CoreGraphics
@testable import Lume
import QuartzCore
import Testing

/// Every logo answers everything the app asks of one, from its design.
@MainActor
struct LogoDesignTests {
    @Test(arguments: LumeLogo.allCases)
    func `each design builds a layer that draws and animates its mark`(logo: LumeLogo) {
        let layer = logo.design.makeMarkLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
        layer.layoutIfNeeded()
        #expect(!(layer.sublayers ?? []).isEmpty)
        layer.motion = .pulse
        #expect((layer.sublayers ?? []).contains { !($0.animationKeys() ?? []).isEmpty })
    }

    @Test(arguments: LumeLogo.allCases)
    func `each design launches, then rests, before the splash's wait`(logo: LumeLogo) {
        let launch = logo.design.launch
        #expect(launch.wordmark.start < launch.wordmark.end)
        #expect(launch.wordmark.end <= launch.duration)
    }

    @Test func `designs have their own names and icon prefixes`() {
        let designs = LumeLogo.allCases.map(\.design)
        #expect(Set(designs.map(\.title)).count == LumeLogo.allCases.count)
        #expect(Set(designs.map(\.iconPrefix)).count == LumeLogo.allCases.count)
        #expect(LumeLogo.afterglow.design.iconPrefix == "Lume")
    }
}
