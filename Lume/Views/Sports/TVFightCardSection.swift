//
//  TVFightCardSection.swift
//  Lume
//
//  The tvOS Match Centre's fight card (UFC, PFL): the main event, and the
//  bout under way when it isn't the main event, as spotlights; then the main
//  card, prelims and early prelims, billed latest first. Results — the
//  winner, method and when it ended — stay hidden under Hide Scores.
//

#if os(tvOS)

    import SwiftUI

    struct TVFightCardSection: View {
        let bouts: [SportsBout]
        let hidesScores: Bool

        private var card: SportsFightCard {
            SportsFightCard(bouts: bouts)
        }

        var body: some View {
            let card = card
            VStack(alignment: .leading, spacing: 36) {
                if let current = card.current {
                    TVBoutSpotlight(title: "Now", bout: current, hidesScores: hidesScores)
                        .tvFocusBlock()
                }
                if let main = card.mainEvent {
                    TVBoutSpotlight(title: "Main Event", bout: main, hidesScores: hidesScores)
                        .tvFocusBlock()
                }
                ForEach(card.segments) { segment in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(segment.kind.title)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                        // Focus, not touch, scrolls a tvOS ScrollView: a long
                        // card is dealt out in focusable blocks.
                        ForEach(Array(segment.bouts.chunked(into: 4).enumerated()), id: \.offset) { _, chunk in
                            VStack(spacing: 4) {
                                ForEach(chunk) { TVBoutRow(bout: $0, hidesScores: hidesScores) }
                            }
                            .tvFocusBlock()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One bout, large: both fighters either side of the result.
    private struct TVBoutSpotlight: View {
        let title: LocalizedStringKey
        let bout: SportsBout
        let hidesScores: Bool

        var body: some View {
            VStack(spacing: 22) {
                HStack(spacing: 12) {
                    Text(title).foregroundStyle(.white)
                    if let line = bout.billingLine {
                        Text(verbatim: "· \(line)").foregroundStyle(.white.opacity(0.6))
                    }
                }
                .font(.system(size: 26, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .center, spacing: 24) {
                    fighter(at: 0, alignment: .leading)
                    TVBoutOutcome(bout: bout, hidesScores: hidesScores, large: true)
                        .frame(width: 260)
                    fighter(at: 1, alignment: .trailing)
                }
            }
        }

        @ViewBuilder
        private func fighter(at index: Int, alignment: HorizontalAlignment) -> some View {
            if bout.fighters.indices.contains(index) {
                let fighter = bout.fighters[index]
                VStack(alignment: alignment, spacing: 10) {
                    TVFighterFlag(url: fighter.flagURL, size: 56)
                    Text(verbatim: fighter.name)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white.opacity(bout.emphasis(of: fighter, hidingScores: hidesScores)))
                        .lineLimit(2)
                        .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                    if let record = fighter.record {
                        Text(verbatim: record)
                            .font(.system(size: 24, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            } else {
                Spacer().frame(maxWidth: .infinity)
            }
        }
    }

    /// A bout on the card: flags and names at either edge, the weight class
    /// and result between them.
    private struct TVBoutRow: View {
        let bout: SportsBout
        let hidesScores: Bool

        var body: some View {
            HStack(spacing: 18) {
                name(at: 0, alignment: .leading)
                VStack(spacing: 4) {
                    if let weight = bout.weightClass {
                        Text(verbatim: weight)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    TVBoutOutcome(bout: bout, hidesScores: hidesScores, large: false)
                }
                .frame(width: 260)
                name(at: 1, alignment: .trailing)
            }
            .padding(.vertical, 10)
        }

        @ViewBuilder
        private func name(at index: Int, alignment: HorizontalAlignment) -> some View {
            if bout.fighters.indices.contains(index) {
                let fighter = bout.fighters[index]
                HStack(spacing: 14) {
                    if alignment == .leading { TVFighterFlag(url: fighter.flagURL, size: 32) }
                    VStack(alignment: alignment, spacing: 2) {
                        Text(verbatim: fighter.name)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white.opacity(bout.emphasis(of: fighter, hidingScores: hidesScores)))
                            .lineLimit(1)
                        if let record = fighter.record {
                            Text(verbatim: record)
                                .font(.system(size: 20, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    if alignment == .trailing { TVFighterFlag(url: fighter.flagURL, size: 32) }
                }
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            } else {
                Spacer().frame(maxWidth: .infinity)
            }
        }
    }

    /// The middle of a bout: "vs" before it starts, Live during it, then the
    /// method and when it ended — or just "vs" under Hide Scores.
    private struct TVBoutOutcome: View {
        let bout: SportsBout
        let hidesScores: Bool
        let large: Bool

        var body: some View {
            VStack(spacing: 6) {
                switch bout.status.state {
                case .inProgress:
                    LiveBadge(fontSize: large ? 22 : 18)
                    if let round = bout.status.period, round > 0 {
                        Text("R\(round)")
                            .font(.system(size: large ? 24 : 20))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                case .final where !hidesScores:
                    Text(bout.method?.title ?? "Draw / No Contest")
                        .font(.system(size: large ? 32 : 24, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let ended = bout.endedAt {
                        Text("R\(ended.round) · \(ended.clock)")
                            .font(.system(size: large ? 24 : 20, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.65))
                    }
                default:
                    Text("vs")
                        .font(.system(size: large ? 32 : 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private struct TVFighterFlag: View {
        let url: URL?
        let size: CGFloat

        var body: some View {
            CachedAsyncImage(url: url, maxPixelSize: size * 2) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: size, height: size * 0.7)
            .accessibilityHidden(true)
        }
    }
#endif
