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

extension SportsFormGame.Result {
    /// The standings table's own letters (W / D / L), translated with it.
    var letter: LocalizedStringKey {
        switch self {
        case .win: "W"
        case .draw: "D"
        case .loss: "L"
        }
    }
}

extension SportsFixture {
    /// Records and form show unless scores are hidden and the game is over,
    /// when they already count its result. Shared by the header's form line
    /// and the form guide.
    func showsForm(hidingScores: Bool) -> Bool {
        !hidingScores || status.state != .final
    }

    /// The form line under a team's crest: the summary's results when it has
    /// them. The scoreboard's own string stands in for other sports; in
    /// soccer it doesn't match the team's results (ESPN's feed), so nothing
    /// shows until the summary arrives.
    func headerForm(for competitor: SportsCompetitor, detail: SportsEventDetail?) -> TeamFormLine.Content? {
        if let games = detail?.form.first(where: { $0.teamId == competitor.team.teamId })?.games, !games.isEmpty {
            return .results(games.map(\.result))
        }
        guard sport != "soccer", let text = competitor.form, !text.isEmpty else { return nil }
        return .text(text)
    }
}

/// A team's recent results under its crest: coloured letters, oldest first.
struct TeamFormLine: View {
    enum Content: Equatable {
        case results([SportsFormGame.Result])
        case text(String)
    }

    let content: Content
    let letterSize: CGFloat
    let textColor: Color

    var body: some View {
        switch content {
        case let .results(results):
            HStack(spacing: letterSize * 0.25) {
                ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                    Text(result.letter)
                        .font(.system(size: letterSize, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: letterSize * 1.45, height: letterSize * 1.45)
                        .background(RoundedRectangle(cornerRadius: letterSize * 0.3, style: .continuous).fill(result.color))
                }
            }
        case let .text(text):
            Text(verbatim: text)
                .font(.system(size: letterSize, design: .monospaced))
                .foregroundStyle(textColor)
        }
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

/// Keep the row's measured height in step with its wrapped prose, including
/// when a focusable tvOS block receives a shorter height proposal.
struct SportsCommentaryRow: View {
    enum Style {
        case sheet, television
    }

    let entry: SportsCommentaryEntry
    var style: Style = .sheet

    private var isTelevision: Bool {
        style == .television
    }

    private var isGoal: Bool {
        entry.kind == .goal || entry.kind == .ownGoal
    }

    var body: some View {
        HStack(alignment: .top, spacing: isTelevision ? 18 : 10) {
            Text(verbatim: entry.minute)
                .font(isTelevision ? .system(size: 24, weight: .semibold).monospacedDigit() : .caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: isTelevision ? 80 : 44, alignment: .leading)
            if entry.kind != nil || isTelevision {
                Group {
                    if let kind = entry.kind { kind.marker }
                }
                .font(isTelevision ? .system(size: 24) : .caption)
                // An unbounded clear shape stretches under a multiline row.
                .frame(width: isTelevision ? 30 : nil, height: isTelevision ? 30 : nil)
                .accessibilityHidden(true)
            }
            Text(verbatim: entry.text)
                .font(isTelevision ? .system(size: 26, weight: isGoal ? .bold : .regular) : .subheadline.weight(isGoal ? .semibold : .regular))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The sheet's Commentary tab: newest first.
struct CommentarySection: View {
    let entries: [SportsCommentaryEntry]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(entries.reversed()) { entry in
                SportsCommentaryRow(entry: entry)
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
            case .draw:
                if let draw = detail.draw { TVTennisDrawSection(draw: draw, fixture: fixture) }
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
                        ForEach(chunk) { SportsCommentaryRow(entry: $0, style: .television) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .tvFocusBlock()
                }
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
