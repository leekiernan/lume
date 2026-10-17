import Foundation

extension WidgetSnapshotExporter {
    #if os(tvOS)
        nonisolated static func exportTV(
            _ snapshot: inout WidgetSnapshot, owner: UUID?,
            canPublish: @escaping @MainActor @Sendable () -> Bool
        ) async {
            let privateArtworkSource = snapshot
            TopShelfPrivateArtwork.applyCached(to: &snapshot)
            // The carousel's art, with each title's logo drawn in, is rendered
            // here rather than in the extension — see `TopShelfCarouselArt`.
            // What's already rendered goes out with the snapshot; the rest
            // follows in a second write once it has rendered.
            let carousel = snapshot.topShelf?.style == .carousel
            if carousel { TopShelfCarouselArt.applyCached(to: &snapshot) }
            guard await publish(snapshot, owner: owner, canPublish: canPublish) else { return }
            if await TopShelfPrivateArtwork.renderMissing(in: &snapshot, source: privateArtworkSource) {
                guard await publish(snapshot, owner: owner, canPublish: canPublish) else { return }
            }
            if carousel, await TopShelfCarouselArt.renderMissing(in: &snapshot) {
                guard await publish(snapshot, owner: owner, canPublish: canPublish) else { return }
            }
            guard !Task.isCancelled, await canPublish() else { return }
            TopShelfCarouselArt.prune(keeping: carousel ? snapshot : WidgetSnapshot(generatedAt: snapshot.generatedAt, sections: []))
            TopShelfPrivateArtwork.prune(keeping: snapshot)
        }
    #endif
}
