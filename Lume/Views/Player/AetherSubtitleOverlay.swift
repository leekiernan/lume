//
//  AetherSubtitleOverlay.swift
//  Lume
//
//  Draws AetherEngine's showing subtitle cues over the video: text in the
//  viewer's `SubtitleStyle`, and bitmap cues (PGS, DVB, DVD) where the disc
//  placed them. Observes only `SubtitleCueModel`, so a cue change redraws this
//  leaf and nothing else.
//

#if !os(visionOS)

    import SwiftUI

    struct AetherSubtitleOverlay: View {
        @ObservedObject var cues: SubtitleCueModel
        /// The picture's size, for placing bitmap cues on the video rect.
        let videoSize: CGSize?
        @AppStorage(SubtitleStyle.storageKey) private var style = SubtitleStyle.default

        var body: some View {
            ZStack {
                if !cues.bitmaps.isEmpty {
                    GeometryReader { geometry in
                        ForEach(cues.bitmaps) { bitmap in
                            let frame = SubtitleBitmap.frame(
                                position: bitmap.position, canvasSize: bitmap.canvasSize,
                                videoSize: videoSize, in: geometry.size
                            )
                            Image(decorative: bitmap.image, scale: 1)
                                .resizable()
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                } else if let text = cues.text {
                    VStack {
                        Spacer()
                        Text(text)
                            .multilineTextAlignment(.center)
                            .subtitleStyle(style)
                    }
                    .padding()
                    .subtitleLift(style.position)
                }
            }
            // Never intercept taps meant for the video or the controls.
            .allowsHitTesting(false)
        }
    }

#endif
