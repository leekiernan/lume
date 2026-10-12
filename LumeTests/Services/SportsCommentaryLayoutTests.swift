#if canImport(UIKit)
    @testable import Lume
    import SwiftUI
    import Testing
    import UIKit

    @MainActor
    struct SportsCommentaryLayoutTests {
        private let prose = String(repeating: "An extended commentary update describing the attack and the players involved. ", count: 6)

        private func row(_ text: String, kind: SportsCommentaryEntry.Kind?, style: SportsCommentaryRow.Style) -> SportsCommentaryRow {
            SportsCommentaryRow(entry: SportsCommentaryEntry(sequence: 1, minute: "90'+12", text: text, kind: kind), style: style)
        }

        private func height(_ view: some View, width: CGFloat, proposedHeight: CGFloat = 1) -> CGFloat {
            let host = UIHostingController(rootView: view)
            return host.sizeThatFits(in: CGSize(width: width, height: proposedHeight)).height
        }

        @Test(arguments: [SportsCommentaryRow.Style.sheet, .television])
        func `wrapped commentary reserves its full height even with a short proposal`(style: SportsCommentaryRow.Style) {
            for kind: SportsCommentaryEntry.Kind? in [nil, .goal, .yellowCard, .substitution] {
                let short = height(row("Kick off.", kind: kind, style: style), width: 420)
                let long = height(row(prose, kind: kind, style: style), width: 420)
                let unconstrained = height(row(prose, kind: kind, style: style), width: 420, proposedHeight: 10000)
                #expect(long > short * 3)
                #expect(abs(long - unconstrained) < 1)
            }
        }

        @Test(arguments: [SportsCommentaryRow.Style.sheet, .television])
        func `neighbouring rows reserve separate space for multiline commentary`(style: SportsCommentaryRow.Style) {
            let first = row(prose, kind: nil, style: style)
            let second = row(prose, kind: .goal, style: style)
            let rows = VStack(alignment: .leading, spacing: 18) {
                first
                second
            }
            .fixedSize(horizontal: false, vertical: true)
            let expected = height(first, width: 420) + height(second, width: 420) + 18
            #expect(abs(height(rows, width: 420) - expected) < 1)
        }

        @Test func `sheet rows also grow for accessibility text sizes`() {
            let commentary = row(prose, kind: .yellowCard, style: .sheet)
            let regular = height(commentary.environment(\.dynamicTypeSize, .large), width: 420)
            let accessible = height(commentary.environment(\.dynamicTypeSize, .accessibility3), width: 420)
            #expect(accessible > regular)
        }
    }
#endif
