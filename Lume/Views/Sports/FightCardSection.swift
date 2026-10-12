//
//  FightCardSection.swift
//  Lume
//
//  The game-detail sheet's fight card (UFC, PFL) on iOS, iPadOS and macOS:
//  the main event, and the bout under way when it isn't the main event, then
//  the main card, prelims and early prelims, billed latest first. The tvOS
//  Match Centre has its own 10-foot version (`TVFightCardSection`); both read
//  `SportsFightCard`. Results stay hidden under Hide Scores.
//

import SwiftUI

struct FightCardSection: View {
    let bouts: [SportsBout]
    let hidesScores: Bool

    var body: some View {
        let card = SportsFightCard(bouts: bouts)
        VStack(spacing: 16) {
            if card.current != nil || card.mainEvent != nil {
                VStack(spacing: 14) {
                    if let current = card.current {
                        BoutSpotlight(title: "Now", bout: current, hidesScores: hidesScores)
                    }
                    if card.current != nil, card.mainEvent != nil {
                        Divider()
                    }
                    if let main = card.mainEvent {
                        BoutSpotlight(title: "Main Event", bout: main, hidesScores: hidesScores)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
            }
            ForEach(card.segments) { segment in
                VStack(alignment: .leading, spacing: 10) {
                    Text(segment.kind.title)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(segment.bouts.enumerated()), id: \.element.id) { index, bout in
                        if index > 0 { Divider() }
                        BoutRow(bout: bout, hidesScores: hidesScores)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

/// One bout, larger: the billing line over both fighters and the result.
private struct BoutSpotlight: View {
    let title: LocalizedStringKey
    let bout: SportsBout
    let hidesScores: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold)
                if let line = bout.billingLine {
                    Text(verbatim: "· \(line)").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            BoutLine(bout: bout, hidesScores: hidesScores, prominent: true)
        }
    }
}

private struct BoutRow: View {
    let bout: SportsBout
    let hidesScores: Bool

    var body: some View {
        BoutLine(bout: bout, hidesScores: hidesScores, prominent: false)
            .padding(.vertical, 2)
    }
}

/// Both fighters at either edge, the weight class and result between.
private struct BoutLine: View {
    let bout: SportsBout
    let hidesScores: Bool
    let prominent: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            fighter(at: 0, alignment: .leading)
            VStack(spacing: 2) {
                if !prominent, let weight = bout.weightClass {
                    Text(verbatim: weight)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                outcome
            }
            .frame(width: prominent ? 120 : 104)
            fighter(at: 1, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var outcome: some View {
        switch bout.status.state {
        case .inProgress:
            LiveBadge()
            if let round = bout.status.period, round > 0 {
                Text("R\(round)").font(.caption).foregroundStyle(.secondary)
            }
        case .final where !hidesScores:
            Text(bout.method?.title ?? "Draw / No Contest")
                .font(prominent ? .subheadline.weight(.bold) : .caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let ended = bout.endedAt {
                Text("R\(ended.round) · \(ended.clock)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        default:
            Text("vs")
                .font(prominent ? .headline : .subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func fighter(at index: Int, alignment: HorizontalAlignment) -> some View {
        if bout.fighters.indices.contains(index) {
            let fighter = bout.fighters[index]
            let leading = alignment == .leading
            HStack(spacing: 8) {
                if leading { FighterFlag(url: fighter.flagURL, size: prominent ? 28 : 20) }
                VStack(alignment: alignment, spacing: 1) {
                    Text(verbatim: prominent ? fighter.name : fighter.shortName ?? fighter.name)
                        .font(prominent ? .headline : .subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(leading ? .leading : .trailing)
                        .opacity(bout.emphasis(of: fighter, hidingScores: hidesScores))
                    if let record = fighter.record {
                        Text(verbatim: record)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if !leading { FighterFlag(url: fighter.flagURL, size: prominent ? 28 : 20) }
            }
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
        } else {
            Spacer().frame(maxWidth: .infinity)
        }
    }
}

private struct FighterFlag: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        CachedAsyncImage(url: url, maxPixelSize: size * 3) { phase in
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
