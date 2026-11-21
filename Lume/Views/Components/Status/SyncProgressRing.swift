//
//  SyncProgressRing.swift
//  Lume
//
//  The determinate ring the compact sync surfaces draw: the library toolbar's
//  Sync button and the empty-library placeholder.
//

import SwiftUI

/// Drawn in the foreground style, so the caller picks the colour — never
/// `Color.accentColor` on tvOS, where it resolves to white on its own.
struct SyncProgressRing: View {
    /// 0...1. A sliver is always drawn so a sync that has just started still
    /// reads as a ring in motion rather than an empty track.
    let fraction: Double
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0.03, fraction)))
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .animation(.smooth(duration: 0.4), value: fraction)
    }
}

extension SyncProgress {
    /// The overall progress as a whole percentage, for the ring's label.
    var overallPercent: Text {
        Text(overallFraction, format: .percent.precision(.fractionLength(0)))
    }
}

#Preview {
    HStack(spacing: 24) {
        SyncProgressRing(fraction: 0).frame(width: 44, height: 44)
        SyncProgressRing(fraction: 0.4).frame(width: 44, height: 44)
        SyncProgressRing(fraction: 1).frame(width: 44, height: 44)
    }
    .foregroundStyle(Color.lumeAccent)
    .padding()
}
