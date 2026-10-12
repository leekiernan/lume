//
//  PitchLineupViews.swift
//  Lume
//
//  A match's starting lineups on a pitch, both teams facing each other:
//  across the screen on tvOS (home attacking right), up and down it in the
//  iPhone, iPad and Mac sheet (home attacking up). Soccer's spots come from
//  `SoccerPitchLayout`, rugby union's from `RugbyPitchLayout`; when either
//  lineup can't be placed exactly, the Lineup tab keeps its list.
//

import SwiftUI

/// The pitches a lineup can be drawn on, in metres, ends left and right.
enum PitchField {
    case soccer, rugby

    init?(sport: String) {
        switch sport {
        case "soccer": self = .soccer
        case "rugby": self = .rugby
        default: return nil
        }
    }

    /// End to end — for rugby, dead-ball line to dead-ball line.
    var length: CGFloat {
        self == .soccer ? 105 : 120
    }

    var width: CGFloat {
        self == .soccer ? 68 : 70
    }

    /// Fifteen a side need smaller markers than eleven.
    var markerScale: CGFloat {
        self == .soccer ? 1 : 0.8
    }

    /// Where a spot's depth (0 its own goal or try line, 1 halfway) falls
    /// along the whole pitch, 0 to 1, for the side defending the left end.
    func along(_ depth: Double) -> Double {
        switch self {
        case .soccer: depth * 0.5
        case .rugby: (10 + 50 * depth) / 120
        }
    }

    func spots(for lineup: SportsLineup) -> [PitchSpot]? {
        switch self {
        case .soccer: SoccerPitchLayout.spots(for: lineup)
        case .rugby: RugbyPitchLayout.spots(for: lineup)
        }
    }
}

/// Both sides' spots, or nothing to draw.
struct PitchLineups {
    let field: PitchField
    let home: [PitchSpot]
    let away: [PitchSpot]
    let homePalette: TeamPalette
    let awayPalette: TeamPalette
    let homeTitle: String
    let awayTitle: String

    init?(lineups: [SportsLineup], fixture: SportsFixture) {
        guard let field = PitchField(sport: fixture.sport),
              let homeID = fixture.home?.team.teamId, let awayID = fixture.away?.team.teamId,
              let homeLineup = lineups.first(where: { $0.teamId == homeID }),
              let awayLineup = lineups.first(where: { $0.teamId == awayID }),
              let home = field.spots(for: homeLineup), let away = field.spots(for: awayLineup)
        else { return nil }
        self.field = field
        self.home = home
        self.away = away
        homePalette = fixture.homePalette
        awayPalette = fixture.awayPalette
        homeTitle = Self.title(fixture.home?.team.shortName, homeLineup.formation)
        awayTitle = Self.title(fixture.away?.team.shortName, awayLineup.formation)
    }

    private static func title(_ team: String?, _ formation: String?) -> String {
        [team, formation].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Pitch markings for a pitch `horizontal` (ends left and right) or upright.
struct PitchMarkings: Shape {
    let field: PitchField
    let horizontal: Bool

    func path(in rect: CGRect) -> Path {
        // Laid out in metres, ends left and right, then turned.
        let length = field.length, width = field.width
        /// `along` runs end to end, `across` touchline to touchline, in metres.
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            horizontal
                ? CGPoint(x: rect.minX + along / length * rect.width, y: rect.minY + across / width * rect.height)
                : CGPoint(x: rect.minX + across / width * rect.width, y: rect.maxY - along / length * rect.height)
        }
        func box(_ near: CGFloat, _ far: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> Path {
            Path { path in path.addLines([point(near, top), point(far, top), point(far, bottom), point(near, bottom), point(near, top)]) }
        }
        var path = box(0, length, 0, width)
        path.move(to: point(length / 2, 0))
        path.addLine(to: point(length / 2, width))
        guard field == .soccer else {
            // Try lines, the 22s and the 10-metre lines.
            for line: CGFloat in [10, 32, 50, 70, 88, 110] {
                path.move(to: point(line, 0))
                path.addLine(to: point(line, width))
            }
            return path
        }
        let unit = (horizontal ? rect.width / length : rect.height / length)
        path.addEllipse(in: CGRect(origin: point(length / 2, width / 2), size: .zero).insetBy(dx: -9.15 * unit, dy: -9.15 * unit))
        for (goal, inward) in [(CGFloat(0), CGFloat(1)), (length, -1)] {
            path.addPath(box(goal, goal + inward * 16.5, width / 2 - 20.16, width / 2 + 20.16))
            path.addPath(box(goal, goal + inward * 5.5, width / 2 - 9.16, width / 2 + 9.16))
        }
        return path
    }
}

/// A starter: shirt number in the team's colour, surname below.
struct PitchPlayerMarker: View {
    let player: SportsLineupPlayer
    let color: Color
    let size: CGFloat
    let nameFont: Font

    var body: some View {
        VStack(spacing: size * 0.12) {
            Text(verbatim: player.jersey ?? "")
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(color))
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: max(1.5, size * 0.05)))
            Text(verbatim: surname)
                .font(nameFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .frame(width: size * 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [player.jersey, player.name].compactMap(\.self).joined(separator: " ")))
    }

    private var surname: String {
        player.name.split(separator: " ").last.map(String.init) ?? player.name
    }
}

/// The pitch with both elevens. `horizontal` puts home on the left
/// attacking right; otherwise home is at the bottom attacking up.
struct PitchLineupCanvas: View {
    let lineups: PitchLineups
    let horizontal: Bool
    let markerSize: CGFloat
    let nameFont: Font

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.12, green: 0.32, blue: 0.2).opacity(0.55))
                PitchMarkings(field: lineups.field, horizontal: horizontal)
                    .stroke(.white.opacity(0.3), lineWidth: 2)
                    .padding(markerSize * 0.25)
                ForEach(lineups.home, id: \.self) { spot in
                    marker(spot, color: lineups.homePalette.primary).position(position(spot, home: true, in: size))
                }
                ForEach(lineups.away, id: \.self) { spot in
                    marker(spot, color: lineups.awayPalette.primary).position(position(spot, home: false, in: size))
                }
            }
        }
        .aspectRatio(horizontal ? lineups.field.length / lineups.field.width : lineups.field.width / lineups.field.length, contentMode: .fit)
    }

    private func marker(_ spot: PitchSpot, color: Color) -> some View {
        PitchPlayerMarker(player: spot.player, color: color, size: markerSize * lineups.field.markerScale, nameFont: nameFont)
    }

    /// Facing the opponent, a team's left is the top of a horizontal pitch
    /// for home and the bottom for away; upright, home's left is the left.
    private func position(_ spot: PitchSpot, home: Bool, in size: CGSize) -> CGPoint {
        let along = home ? lineups.field.along(spot.depth) : 1 - lineups.field.along(spot.depth)
        let across = home ? spot.lateral : 1 - spot.lateral
        // Markers stay clear of the touchlines; the name hangs below.
        let inset = markerSize * 0.9
        let point = horizontal ? CGPoint(x: along, y: across) : CGPoint(x: across, y: 1 - along)
        return CGPoint(
            x: inset + point.x * (size.width - 2 * inset),
            y: inset + point.y * (size.height - 2 * inset)
        )
    }
}

#if os(tvOS)

    /// The tvOS Lineup tab: the pitch when both sides can be placed, else
    /// the list.
    struct TVLineupTab: View {
        let lineups: [SportsLineup]
        let fixture: SportsFixture

        var body: some View {
            if let pitch = PitchLineups(lineups: lineups, fixture: fixture) {
                VStack(spacing: 16) {
                    HStack {
                        Text(verbatim: pitch.homeTitle)
                        Spacer()
                        Text(verbatim: pitch.awayTitle)
                    }
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    PitchLineupCanvas(lineups: pitch, horizontal: true, markerSize: 46, nameFont: .system(size: 18, weight: .semibold))
                }
                .tvFocusBlock()
            } else {
                TVLineupSection(lineups: lineups, fixture: fixture)
            }
        }
    }

#endif

/// The sheet's Lineup tab: the pitch when both sides can be placed, else
/// the list.
struct LineupTab: View {
    let lineups: [SportsLineup]
    let fixture: SportsFixture

    var body: some View {
        if let pitch = PitchLineups(lineups: lineups, fixture: fixture) {
            VStack(spacing: 8) {
                Text(verbatim: pitch.awayTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                PitchLineupCanvas(lineups: pitch, horizontal: false, markerSize: 26, nameFont: .caption2.weight(.semibold))
                Text(verbatim: pitch.homeTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        } else {
            LineupSection(lineups: lineups, fixture: fixture)
        }
    }
}
