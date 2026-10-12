import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// A stand-in video frame with a sample cue drawn in `style`, for the Subtitle
/// Style settings. The frame is laid out at the size of a full-screen player and
/// scaled down to fit, and the cue goes through the same `subtitleStyle` /
/// `subtitleLift` the player overlays use — so text size, edge and position read
/// in proportion to the picture exactly as they will during playback.
struct SubtitleStylePreview: View {
    let style: SubtitleStyle

    /// Roughly the player's full-screen size on this platform.
    private static var canvas: CGSize {
        #if os(tvOS)
            CGSize(width: 1920, height: 1080)
        #elseif os(macOS) || os(visionOS)
            CGSize(width: 1280, height: 720)
        #else
            if UIDevice.current.userInterfaceIdiom == .phone {
                CGSize(width: 720, height: 405)
            } else {
                CGSize(width: 1180, height: 664)
            }
        #endif
    }

    private let sample: LocalizedStringKey = "Subtitles will look like this.\nPick a style that's easy to read."

    var body: some View {
        let canvas = Self.canvas
        GeometryReader { proxy in
            let scale = min(proxy.size.width / canvas.width, proxy.size.height / canvas.height)
            ZStack {
                SubtitlePreviewBackdrop()
                Text(sample)
                    .multilineTextAlignment(.center)
                    .subtitleStyle(style)
                    // KSSubtitleOverlay's padding plus KSPlayer's default 10 pt
                    // bottom margin, so the cue sits where the player puts it.
                    .padding(.horizontal)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .subtitleLift(style.position)
            }
            .frame(width: canvas.width, height: canvas.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Subtitle preview"))
        .accessibilityValue(Text(sample))
    }
}

/// An abstract dusk scene: a dark sky over a horizon that runs from bright on
/// the left to dark on the right, so one cue shows how the style reads on both.
private struct SubtitlePreviewBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.09, green: 0.13, blue: 0.3),
                        Color(red: 0.42, green: 0.32, blue: 0.55),
                        Color(red: 0.95, green: 0.58, blue: 0.42)
                    ],
                    startPoint: .top,
                    endPoint: .center
                )

                Circle()
                    .fill(Color(red: 1, green: 0.88, blue: 0.62))
                    .frame(width: size.height * 0.22)
                    .blur(radius: size.height * 0.02)
                    .position(x: size.width * 0.3, y: size.height * 0.5)

                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.84, blue: 0.62),
                        Color(red: 0.55, green: 0.42, blue: 0.4),
                        Color(red: 0.06, green: 0.1, blue: 0.16)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: size.height * 0.45)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        SubtitleStylePreview(style: .default)
        SubtitleStylePreview(style: SubtitleStyle(size: .large, textColor: .yellow, background: .semiOpaque, edge: .outline, position: .higher))
    }
    .padding()
}
