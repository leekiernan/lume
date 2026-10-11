//
//  MatchExtrasViews.swift
//  Lume
//
//  A soccer match's form guide and text commentary (`SportsMatchExtras`) in
//  the game details, plus the tvOS tab switch they joined. The form guide
//  reads left to right, oldest to latest, each result a pill coloured by its
//  outcome; the commentary runs newest first. Both are kept back under Hide
//  Scores by their callers.
//

import SwiftUI

// MARK: - Form guide

extension SportsFormGame.Result {
    var color: Color {
        switch self {
        case .win: Color(red: 0.18, green: 0.62, blue: 0.33)
        case .draw: Color(white: 0.45)
        case .loss: Color(red: 0.78, green: 0.22, blue: 0.22)
        }
    }
}

extension SportsFormGame {
    /// "Won 2-1 against SUN, away".
    var accessibilityText: String {
        let score = scoreLine ?? ""
        let line = switch result {
        case .win: String(localized: "Won \(score) against \(opponentName ?? opponent)")
        case .draw: String(localized: "Drew \(score) with \(opponentName ?? opponent)")
        case .loss: String(localized: "Lost \(score) to \(opponentName ?? opponent)")
        }
        return line + ", " + (isHome ? String(localized: "home") : String(localized: "away"))
    }
}

/// One result: the score from the team's side over the opponent's code,
/// "@" marking an away game.
struct FormResultPill: View {
    let game: SportsFormGame
    let scoreFont: Font
    let opponentFont: Font
    let width: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: game.scoreLine ?? game.result.rawValue)
                .font(scoreFont)
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(verbatim: game.isHome ? game.opponent : "@\(game.opponent)")
                .font(opponentFont)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: width)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(game.result.color))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: game.accessibilityText))
    }
}

/// Both sides' forms, home first, with the team each belongs to.
struct MatchForms {
    let rows: [(team: SportsTeam, form: SportsTeamForm)]

    init?(detail: SportsEventDetail?, fixture: SportsFixture) {
        let rows = [fixture.home?.team, fixture.away?.team].compactMap { team -> (team: SportsTeam, form: SportsTeamForm)? in
            guard let team, let form = detail?.form.first(where: { $0.teamId == team.teamId }) else { return nil }
            return (team, form)
        }
        guard !rows.isEmpty else { return nil }
        self.rows = rows
    }
}

// MARK: - Commentary

extension SportsCommentaryEntry.Kind {
    @ViewBuilder
    var marker: some View {
        switch self {
        case .goal: Image(systemName: "soccerball")
        case .ownGoal: Image(systemName: "soccerball").foregroundStyle(.red)
        case .yellowCard: RoundedRectangle(cornerRadius: 2).fill(.yellow).frame(width: 9, height: 13)
        case .redCard: RoundedRectangle(cornerRadius: 2).fill(.red).frame(width: 9, height: 13)
        case .substitution: Image(systemName: "arrow.left.arrow.right")
        }
    }
}

/// The sheet's Commentary tab: newest first.
struct CommentarySection: View {
    let entries: [SportsCommentaryEntry]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(entries.reversed()) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: entry.minute)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    if let kind = entry.kind {
                        kind.marker.font(.caption)
                    }
                    Text(verbatim: entry.text)
                        .font(entry.kind == .goal || entry.kind == .ownGoal ? .subheadline.weight(.semibold) : .subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}

#if os(tvOS)

    /// The tvOS Match Centre's selected tab.
    struct TVDetailTabContent: View {
        let detail: SportsEventDetail
        let fixture: SportsFixture
        let tab: GameDetailTab
        let hidesScores: Bool

        var body: some View {
            let tabs = detail.availableTabs(hidingScores: hidesScores)
            switch tabs.contains(tab) ? tab : tabs.first {
            case .timeline:
                TVTimelineSection(events: detail.keyEvents, fixture: fixture)
            case .stats:
                TVStatsSection(stats: detail.teamStats, homePalette: fixture.homePalette, awayPalette: fixture.awayPalette)
            case .lineup:
                TVLineupTab(lineups: detail.lineups, fixture: fixture)
            case .commentary:
                TVCommentarySection(entries: detail.commentary)
            case nil:
                EmptyView()
            }
        }
    }

    /// The tvOS Commentary tab: newest first, in focusable blocks so focus
    /// can scroll down a full match of it.
    struct TVCommentarySection: View {
        let entries: [SportsCommentaryEntry]

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Array(entries.reversed()).chunked(into: 6).enumerated()), id: \.offset) { _, chunk in
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(chunk) { row($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tvFocusBlock()
                }
            }
        }

        private func row(_ entry: SportsCommentaryEntry) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(verbatim: entry.minute)
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 80, alignment: .leading)
                Group {
                    if let kind = entry.kind { kind.marker } else { Color.clear }
                }
                .font(.system(size: 24))
                .frame(width: 30)
                Text(verbatim: entry.text)
                    .font(.system(size: 26, weight: entry.kind == .goal || entry.kind == .ownGoal ? .bold : .regular))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The tvOS form-guide panel: a row per side.
    struct TVFormPanel: View {
        let forms: MatchForms

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Form")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                ForEach(forms.rows, id: \.team.id) { row in
                    HStack(spacing: 14) {
                        TeamCrest(team: row.team, size: 36).accessibilityHidden(true)
                        Text(verbatim: row.team.abbreviation)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 80, alignment: .leading)
                        ForEach(Array(row.form.games.enumerated()), id: \.offset) { _, game in
                            FormResultPill(game: game, scoreFont: .system(size: 22, weight: .bold), opponentFont: .system(size: 16, weight: .semibold), width: 84)
                        }
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(0.06)))
        }
    }

#endif

/// The sheet's form-guide rows, inside its extras card.
struct FormGuideRows: View {
    let forms: MatchForms

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Form").font(.subheadline.weight(.bold))
            ForEach(forms.rows, id: \.team.id) { row in
                HStack(spacing: 6) {
                    Text(verbatim: row.team.abbreviation)
                        .font(.caption.weight(.bold))
                        .frame(width: 40, alignment: .leading)
                    ForEach(Array(row.form.games.enumerated()), id: \.offset) { _, game in
                        FormResultPill(game: game, scoreFont: .caption.weight(.bold), opponentFont: .caption2, width: 50)
                    }
                }
            }
        }
    }
}
