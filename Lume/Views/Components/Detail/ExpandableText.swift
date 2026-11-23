//
//  ExpandableText.swift
//  Lume
//
//  The expandable synopsis used on the movie and series detail screens. Split
//  out from MediaDetailComponents so each file stays focused.
//

import SwiftUI

/// A synopsis that collapses to a few lines with a "more" affordance. The toggle
/// is only shown when the text genuinely overflows the collapsed line limit —
/// measured from the rendered layout rather than guessed from a character count.
struct ExpandableText: View {
    let text: String
    var collapsedLineLimit: Int = 3

    @State private var isExpanded = false
    /// True once the full text is actually taller than the collapsed line
    /// limit allows (`TruncationProbe`).
    @State private var isExpandable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) {
                    TruncationProbe(lineLimit: collapsedLineLimit, isTruncated: $isExpandable) {
                        Text(text).font(.callout)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isExpanded)

            if isExpandable {
                Button(LocalizedStringKey(isExpanded ? "less" : "more")) {
                    isExpanded.toggle()
                }
                .font(.callout.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
    }
}

#Preview("ExpandableText - Short") {
    ExpandableText(text: "A short synopsis that doesn't need a more/less toggle.")
        .padding()
}

#Preview("ExpandableText - Long") {
    ExpandableText(
        text: "This is a very long synopsis that will definitely need a more/less toggle to expand or collapse "
            + "because it exceeds the character limit we've set. The quick brown fox jumps over the lazy dog. "
            + "This text keeps going and going until it crosses the threshold where the toggle becomes useful "
            + "for the user to read the full content without taking up too much space initially."
    )
    .padding()
}
