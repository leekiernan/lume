//
//  LaunchSplash.swift
//  Lume
//
//  The launch screen's logo, carried on over the app until Home has something
//  to show — see `LaunchCover`. tvOS only: elsewhere Home draws placeholders
//  while it loads.
//

import OSLog
import SwiftUI

@MainActor
@Observable
final class LaunchSplashModel {
    private(set) var cover = LaunchCover()
    /// Home's brand shows once per launch, as the splash lifts.
    var hasShownBrand = false
    private let shownAt = Date()

    func send(_ event: LaunchCover.Event) {
        guard cover.handle(event), case let .revealed(reason) = cover.state else { return }
        let seconds = Date().timeIntervalSince(shownAt)
        Logger.home.info("launch splash lifted (\(reason.rawValue, privacy: .public)) after \(seconds, format: .fixed(precision: 1))s")
    }
}

/// The splash itself: the launch screen's plain Ink, the mark building up on
/// it as its logo board's launch has it, the ambient glows fading in alongside,
/// then the wordmark (`LaunchSplashPhase`). If Home is still not ready after
/// that, the mark pulses as the wait indicator.
///
/// The launch screen is drawn before any code runs and names one image in
/// `Info.plist`, which could match neither the colour theme nor the logo. So it
/// is plain Ink, and both logos' launches start from nothing, as their boards
/// do.
struct LaunchSplashView: View {
    @State private var phase = LaunchSplashPhase.handOver
    @State private var logo = LumeThemeStore.shared.logo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // The launch screen's plain Ink, the glows fading in over it.
            Color.lumeInk.ignoresSafeArea()
            LumeAmbientBackground(style: .brand)
                .opacity(phase.showsGlows ? 1 : 0)
            VStack(spacing: LaunchSplashMetrics.gap) {
                LumeMark(motion: phase.markMotion, logo: logo)
                    .frame(width: LaunchSplashMetrics.mark, height: LaunchSplashMetrics.mark)
                LumeWordmark(size: LaunchSplashMetrics.wordmark, color: Color(white: 0.96))
                    // The board's line-height: 1.
                    .frame(height: LaunchSplashMetrics.wordmark)
                    .opacity(phase.showsWordmark ? 1 : 0)
                    .offset(y: phase.showsWordmark ? 0 : 14)
            }
        }
        .task {
            var elapsed = 0.0
            for step in LaunchSplashPhase.timeline(for: logo, reduceMotion: reduceMotion) {
                try? await Task.sleep(for: .seconds(step.seconds - elapsed))
                guard !Task.isCancelled else { return }
                elapsed = step.seconds
                withAnimation(step.animation) { phase = step.phase }
            }
        }
    }
}

/// Where the splash is in the launch. Only moves forward; what each part of
/// the splash shows follows from it.
nonisolated enum LaunchSplashPhase: Int, Comparable {
    /// The launch screen's frame: plain Ink.
    case handOver
    /// The mark builds up and the glows fade in.
    case launching
    /// The wordmark has risen in.
    case branded
    /// Home still isn't ready: the mark pulses as the wait indicator.
    case waiting

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var showsGlows: Bool {
        self >= .launching
    }

    var showsWordmark: Bool {
        self >= .branded
    }

    var markMotion: LumeMark.Motion {
        self == .waiting ? .pulse : .launch
    }

    struct Step {
        /// Seconds after the splash appears.
        let seconds: TimeInterval
        let phase: LaunchSplashPhase
        let animation: Animation?
    }

    /// The logo board's launch: the glows fade in as the mark builds; the
    /// wordmark rises in when the board brings it (at once with Reduce
    /// Motion); the wait pulse once the mark has rested.
    static func timeline(for logo: LumeLogo, reduceMotion: Bool) -> [Step] {
        let launch = logo.launch
        let wordmarkLength = launch.wordmark.end - launch.wordmark.start
        return [
            Step(seconds: 0, phase: .launching, animation: .easeInOut(duration: LaunchSplashMetrics.glowFade)),
            Step(seconds: reduceMotion ? 0 : launch.wordmark.start, phase: .branded,
                 animation: reduceMotion ? nil : .easeOut(duration: wordmarkLength)),
            Step(seconds: launch.duration + 0.4, phase: .waiting, animation: nil)
        ]
    }
}

extension LumeLogo {
    /// Its launch's timings: when the wordmark arrives, and when it rests.
    nonisolated var launch: (wordmark: (start: Double, end: Double), duration: Double) {
        switch self {
        case .afterglow: (LumeMarkFrame.wordmarkWindow, LumeMarkFrame.launchDuration)
        case .floodlight: (FloodlightFrame.wordmarkWindow, FloodlightFrame.launchDuration)
        }
    }
}

/// The splash's layout: a 300-point mark over the wordmark's space, centred
/// together.
nonisolated enum LaunchSplashMetrics {
    /// The glows' fade in, over the mark's build.
    static let glowFade: TimeInterval = 0.8
    static let mark: CGFloat = 300
    static let gap: CGFloat = 12
    static let wordmark: CGFloat = 88
}

private struct LaunchSplashCover: ViewModifier {
    let homeShown: Bool
    @State private var model = LaunchSplashModel()

    func body(content: Content) -> some View {
        content
            .environment(model)
            .overlay {
                if model.cover.isCovering {
                    LaunchSplashView()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.35), value: model.cover.isCovering)
            .task {
                try? await Task.sleep(for: LaunchCover.longest)
                model.send(.timedOut)
            }
            .onChange(of: homeShown, initial: true) { _, shown in
                if !shown { model.send(.otherTabShown) }
            }
    }
}

/// Home's brand, top leading beside the tab bar: revealed as the splash lifts
/// over Home, and gone a few seconds later. Once per launch.
private struct LaunchBrandOverlay: ViewModifier {
    @Environment(LaunchSplashModel.self) private var splash: LaunchSplashModel?
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isVisible {
                    HStack(spacing: 8) {
                        LumeMark()
                            .frame(width: 60, height: 60)
                        LumeWordmark(size: 32, color: Color(white: 0.96))
                    }
                    .padding(.leading, 80)
                    .padding(.top, 50)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .task(id: splash?.cover.state) {
                guard let splash, !splash.hasShownBrand,
                      case let .revealed(reason) = splash.cover.state, reason != .homeNotShown else { return }
                splash.hasShownBrand = true
                // Already up as the splash fades off it; the board holds it
                // about 3.4 s, then fades it out.
                isVisible = true
                try? await Task.sleep(for: .seconds(3.4))
                withAnimation(.easeInOut(duration: 0.9)) { isVisible = false }
            }
    }
}

extension View {
    /// Home's brand, briefly, as the launch splash lifts.
    func launchBrand() -> some View {
        modifier(LaunchBrandOverlay())
    }

    /// Covers the app with the launch splash until Home has something to show.
    func launchSplash(homeShown: Bool) -> some View {
        modifier(LaunchSplashCover(homeShown: homeShown))
    }
}
