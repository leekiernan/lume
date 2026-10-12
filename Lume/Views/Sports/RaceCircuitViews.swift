//
//  RaceCircuitViews.swift
//  Lume
//
//  A race weekend's circuit in the game detail: its outline beside the name,
//  length and laps — "62 Laps" before a race or sprint, "Lap 34/62" while it
//  runs, then the distance actually run. Practice and qualifying run to time,
//  so they show the circuit alone. Outlines and lengths are bundled
//  (`SportsCircuits`); the laps run come from the provider.
//

import SwiftUI

/// A circuit outline fitted to its frame without distortion.
struct CircuitOutline: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        let horizontal = points.map(\.x), vertical = points.map(\.y)
        guard let minX = horizontal.min(), let maxX = horizontal.max(), let minY = vertical.min(), let maxY = vertical.max(),
              maxX > minX || maxY > minY else { return Path() }
        let scale = min(rect.width / max(maxX - minX, .ulpOfOne), rect.height / max(maxY - minY, .ulpOfOne))
        let offset = CGPoint(
            x: rect.minX + (rect.width - (maxX - minX) * scale) / 2,
            y: rect.minY + (rect.height - (maxY - minY) * scale) / 2
        )
        var path = Path()
        for (index, point) in points.enumerated() {
            let mapped = CGPoint(x: offset.x + (point.x - minX) * scale, y: offset.y + (point.y - minY) * scale)
            if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
        }
        return path
    }
}

/// What the circuit block says about a race weekend or one of its sessions.
nonisolated struct RaceCircuitSummary {
    let circuit: SportsCircuit
    /// The session the laps describe: the card's own, or the weekend's race.
    let session: SportsSession?
    let scheduledLaps: Int?

    /// `sessions` overrides the fixture's own, for a view holding an older copy.
    init?(fixture: SportsFixture, sessions: [SportsSession]? = nil) {
        guard let circuit = SportsCircuits.circuit(id: fixture.circuitID) else { return nil }
        self.circuit = circuit
        let kind = fixture.sessionKind ?? .race
        session = (sessions ?? fixture.sessions).first { $0.kind == kind }
        scheduledLaps = SportsCircuits.scheduledLaps(for: kind, circuitID: fixture.circuitID)
    }

    var isRunning: Bool {
        session?.state == .inProgress
    }

    /// "4.93 km".
    var lengthText: String {
        Measurement(value: Double(circuit.length) / 1000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(2))))
    }

    /// The laps line, hiding what a finished distance would give away. `nil`
    /// for timed sessions.
    func lapsText(hidingScores: Bool) -> String? {
        guard let scheduled = scheduledLaps else { return nil }
        if isRunning, let run = session?.laps {
            return String(localized: "Lap \(run)/\(scheduled)")
        }
        // A race cut short ran fewer laps than scheduled: that's the result.
        let laps = session?.state == .final && !hidingScores ? session?.laps ?? scheduled : scheduled
        return String(localized: "\(laps) Laps")
    }
}

#if os(tvOS)

    struct TVRaceCircuitSection: View {
        let summary: RaceCircuitSummary
        let hidesScores: Bool

        var body: some View {
            HStack(alignment: .center, spacing: 48) {
                CircuitOutline(points: summary.circuit.outline)
                    .stroke(.white, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .shadow(color: .white.opacity(0.25), radius: 8)
                    .aspectRatio(summary.circuit.aspectRatio, contentMode: .fit)
                    .frame(maxWidth: 420, maxHeight: 260)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: summary.circuit.name)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let laps = summary.lapsText(hidingScores: hidesScores) {
                        Text(verbatim: laps)
                            .font(.system(size: summary.isRunning ? 56 : 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    Text(verbatim: summary.lengthText)
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

#endif

/// The game-detail sheet's circuit card (iOS, iPadOS, macOS).
struct RaceCircuitCard: View {
    let summary: RaceCircuitSummary
    let hidesScores: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            CircuitOutline(points: summary.circuit.outline)
                .stroke(.primary, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .aspectRatio(summary.circuit.aspectRatio, contentMode: .fit)
                .frame(maxWidth: 150, maxHeight: 110)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: summary.circuit.name)
                    .font(.headline)
                    .lineLimit(2)
                if let laps = summary.lapsText(hidingScores: hidesScores) {
                    Text(verbatim: laps)
                        .font(summary.isRunning ? .title2.weight(.bold) : .subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                Text(verbatim: summary.lengthText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}
