//
//  PlayerSourceMenu.swift
//  Lume
//
//  The controls' Source menu: the copy playing, ticked, and the copies the
//  player can switch to (`PlayerSourceSwitch`). A native
//  menu like the audio, subtitle and favourite ones beside it, with the same
//  items as the detail page's (`TitleSourceMenuItems`); each overlay supplies
//  its own button.
//

import SwiftData
import SwiftUI

struct PlayerSourceMenu<Glyph: View>: View {
    let sources: PlayerSources
    let bridge: PlayerControlsBridge
    /// After a choice: the controls restart their hide deadline.
    let onChoose: () -> Void
    @ViewBuilder let glyph: () -> Glyph
    @Environment(\.modelContext) private var modelContext
    @State private var details = StreamDetailsLoader()

    private var all: [TitleSource] {
        [sources.current] + sources.alternatives.map(\.source)
    }

    var body: some View {
        Menu {
            TitleSourceMenuItems(sources: all, current: sources.current.id, details: details) { source in
                if let option = sources.alternatives.first(where: { $0.source.id == source.id }) {
                    bridge.selectSource?(option)
                }
                onChoose()
            }
        } label: {
            glyph()
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("Source: \(sources.current.title)"))
        .task(id: sources.current.id) { await details.load(all, in: modelContext) }
    }
}
