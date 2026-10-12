//
//  TennisDrawViews.swift
//  Lume
//
//  A tennis match's Draw tab: the tournament's singles draw one round at a
//  time, opening on the match's own round with the match marked. Rows follow
//  the draw's progression order (`SportsTennisDraw`) but carry no bracket
//  lines, since the order of matches feeding an undecided slot is a guess.
//  The tab hides under Hide Scores like the rest of the results.
//

import SwiftUI

nonisolated extension SportsRoundLabel {
    /// A round's short name for a selector: "R2", "QF", "SF", "F".
    static func short(_ round: String) -> LocalizedStringKey {
        switch round.lowercased() {
        case "final": "sports.round.short.final"
        case "semifinal": "sports.round.short.semifinal"
        case "quarterfinal": "sports.round.short.quarterfinal"
        case let lower where lower.hasPrefix("round "):
            if let number = Int(lower.dropFirst("round ".count)) { "sports.round.short.number \(number)" } else { "\(round)" }
        default: "\(round)"
        }
    }
}

extension SportsTennisDraw {
    /// The round to open on: the match's own, else the first still being played.
    func initialRound(for fixture: SportsFixture) -> String? {
        (round(named: fixture.round) ?? rounds.first { $0.matches.contains { $0.state != .final } } ?? rounds.last)?.name
    }
}

/// One match of the draw: a line per slot, sets in columns.
struct DrawMatchRow: View {
    struct Style {
        let nameSize: CGFloat
        let detailSize: CGFloat
        let flagSize: CGFloat
        let lineSpacing: CGFloat
        let primary: Color
        let secondary: Color

        static let regular = Style(nameSize: 15, detailSize: 13, flagSize: 16, lineSpacing: 4, primary: .primary, secondary: .secondary)
        static let large = Style(nameSize: 26, detailSize: 22, flagSize: 30, lineSpacing: 10, primary: .white, secondary: .white.opacity(0.6))
    }

    let match: SportsDrawMatch
    let style: Style

    var body: some View {
        HStack(alignment: .center, spacing: style.nameSize * 0.6) {
            VStack(alignment: .leading, spacing: style.lineSpacing) {
                ForEach(Array(match.players.enumerated()), id: \.offset) { _, player in
                    line(player)
                }
            }
            status
        }
        .accessibilityElement(children: .combine)
    }

    private func line(_ player: SportsDrawPlayer?) -> some View {
        HStack(spacing: style.nameSize * 0.45) {
            CachedAsyncImage(url: player?.flagURL, maxPixelSize: style.flagSize * 2) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: style.flagSize, height: style.flagSize * 0.7)
            .accessibilityHidden(true)
            if let player {
                Text(verbatim: player.name)
                    .font(.system(size: style.nameSize, weight: player.isWinner ? .bold : .regular))
                    .foregroundStyle(style.primary)
                    .lineLimit(1)
                if let seed = player.seed {
                    Text(verbatim: "\(seed)")
                        .font(.system(size: style.detailSize).monospacedDigit())
                        .foregroundStyle(style.secondary)
                        .accessibilityLabel(Text("Seed \(seed)"))
                }
                Spacer(minLength: 0)
                ForEach(Array(player.sets.enumerated()), id: \.offset) { _, set in
                    Text(verbatim: "\(set.games)")
                        .font(.system(size: style.nameSize, weight: player.isWinner ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(style.primary)
                        .frame(width: style.nameSize * 1.1)
                }
            } else {
                Text("TBD")
                    .font(.system(size: style.nameSize))
                    .foregroundStyle(style.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch match.state {
        case .inProgress:
            Text("Live")
                .font(.system(size: style.detailSize, weight: .bold))
                .foregroundStyle(.red)
        case .scheduled:
            if let date = match.date {
                Text(date, format: match.isDayOnly ? .dateTime.weekday(.abbreviated).day() : .dateTime.weekday(.abbreviated).day().hour().minute())
                    .font(.system(size: style.detailSize))
                    .foregroundStyle(style.secondary)
                    .multilineTextAlignment(.trailing)
            }
        default:
            EmptyView()
        }
    }
}

/// The sheet's Draw tab.
struct TennisDrawSection: View {
    let draw: SportsTennisDraw
    let fixture: SportsFixture

    @State private var selection: String?

    var body: some View {
        let current = draw.round(named: selection ?? draw.initialRound(for: fixture)) ?? draw.rounds.last
        VStack(spacing: 12) {
            Picker(selection: Binding(get: { current?.name }, set: { selection = $0 })) {
                ForEach(draw.rounds) { round in
                    Text(SportsRoundLabel.short(round.name)).tag(Optional(round.name))
                }
            } label: {
                EmptyView()
            }
            .hubSegmentedPickerStyle()
            .labelsHidden()

            LazyVStack(spacing: 0) {
                ForEach(current?.matches ?? []) { match in
                    DrawMatchRow(match: match, style: .regular)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(match.id == fixture.id ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear))
                        )
                    Divider()
                }
            }
        }
    }
}

#if os(tvOS)

    /// The tvOS Draw tab: round pills over the round's matches, in focusable
    /// blocks so focus can scroll down a 32-match first round.
    struct TVTennisDrawSection: View {
        let draw: SportsTennisDraw
        let fixture: SportsFixture

        @State private var selection: String?

        var body: some View {
            let current = draw.round(named: selection ?? draw.initialRound(for: fixture)) ?? draw.rounds.last
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    ForEach(draw.rounds) { round in
                        TVTabPill(title: SportsRoundLabel.short(round.name), isActive: round.name == current?.name) {
                            selection = round.name
                        }
                        .accessibilityLabel(Text(verbatim: SportsRoundLabel.localized(round.name)))
                    }
                }
                .focusSection()

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((current?.matches ?? []).chunked(into: 4).enumerated()), id: \.offset) { _, chunk in
                        VStack(spacing: 22) {
                            ForEach(chunk) { match in
                                DrawMatchRow(match: match, style: .large)
                                    .padding(match.id == fixture.id ? 12 : 0)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(.white.opacity(match.id == fixture.id ? 0.14 : 0))
                                    )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tvFocusBlock()
                    }
                }
            }
        }
    }

#endif
