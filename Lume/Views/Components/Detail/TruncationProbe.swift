//
//  TruncationProbe.swift
//  Lume
//
//  Whether a paragraph overflows its collapsed line limit, measured from the
//  rendered layout rather than guessed from a character count: a 200-character
//  synopsis can fit three lines on a wide layout. Shared by the expandable
//  synopsis (`ExpandableText`) and tvOS's About card (`TVAboutText`), which
//  each carried a copy built from geometry readers and preference keys.
//

import SwiftUI

/// Two hidden copies of the text, laid out at the width of whatever it sits
/// behind: one clamped to `lineLimit`, one unbounded. Put it in the visible
/// text's `.background(alignment: .topLeading)`, styled the same way.
struct TruncationProbe<Styled: View>: View {
    let lineLimit: Int
    @Binding var isTruncated: Bool
    @ViewBuilder let text: () -> Styled

    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            text()
                .lineLimit(lineLimit)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { collapsedHeight = $0 }
            text()
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullHeight = $0 }
        }
        .hidden()
        .onChange(of: fullHeight > collapsedHeight + 1, initial: true) { _, truncated in
            isTruncated = truncated
        }
    }
}
