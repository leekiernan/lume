//
//  PersonFilmographyView.swift
//  Lume
//
//  A cast member's titles in the playlist the detail page came from: their
//  headshot over the same grid a Home row's See All opens. A poster pushes its
//  detail page onto the same stack, whose cast can push another person, so the
//  page keeps only ids and the hydrated page of models; covered pages give up
//  their artwork (see `CachedAsyncImage`).
//

import SwiftData
import SwiftUI

struct PersonFilmographyView: View {
    let route: PersonRoute
    var animationNamespace: Namespace.ID?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction

    @State private var entries: [HomeListEntry] = []
    @State private var items: [HomeMediaItem] = []
    @State private var loads = PersonFilmographyLoadMachine()
    @State private var pageTask: Task<Void, Never>?

    private let pageSize = 100

    #if os(tvOS)
        private let headshotSize: CGFloat = TVDetailMetrics.castAvatar
        private let headshotImageSize: TMDBProfileSize = .h632
    #else
        private let headshotSize: CGFloat = 112
        private let headshotImageSize: TMDBProfileSize = .w185
    #endif

    var body: some View {
        CategoryPage(title: route.name) {
            headshot
            CollectionGridContent(
                items: items,
                isLoading: loads.isLoadingCredits || loads.pagination.isLoading,
                isLoadingMore: loads.pagination.isLoading,
                emptyMessage: Text("None of \(route.name)'s films or series are in this playlist."),
                animationNamespace: animationNamespace,
                onReachEnd: requestNextPage
            )
        }
        .task(id: loadKey) { await load() }
        .onDisappear {
            pageTask?.cancel()
            loads.cancelPage()
        }
    }

    private var headshot: some View {
        CachedAsyncImage(url: TMDBClient.profileURL(route.profilePath, size: headshotImageSize), maxPixelSize: headshotSize) { phase in
            switch phase {
            case let .success(image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Rectangle().fill(Color.gray.opacity(0.25))
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: headshotSize * 0.4))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: headshotSize, height: headshotSize)
        .clipShape(Circle())
        .accessibilityHidden(true)
        #if os(tvOS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 20)
        #else
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        #endif
    }

    /// A new person, playlist or set of restrictions starts the page over.
    private var loadKey: String {
        "\(route.personID)|\(route.playlistPrefix)|\(restriction.visibilityToken)"
    }

    private var feedContext: SectionFeed.Context {
        SectionFeed.Context(
            modelContext: modelContext,
            restriction: restriction,
            playlistPrefix: route.playlistPrefix.isEmpty ? nil : route.playlistPrefix
        )
    }

    private func load() async {
        let key = loadKey
        guard let request = loads.beginCredits(for: key) else {
            if items.isEmpty { requestNextPage() }
            return
        }
        pageTask?.cancel()
        entries = []
        items = []
        let remote = await PersonCreditsStore.shared.credits(for: route.personID)
        guard !Task.isCancelled, key == loadKey else {
            loads.abandonCredits(request)
            return
        }
        let resolved = remote ?? PersonFilmography.localEntries(personID: route.personID, in: modelContext)
        guard loads.finishCredits(request, hasEntries: !resolved.isEmpty) else { return }
        entries = resolved
        requestNextPage()
    }

    private func requestNextPage() {
        guard let request = loads.beginPage() else { return }
        let source = entries
        let context = feedContext
        pageTask = Task { await loadNextPage(request, entries: source, context: context) }
    }

    private func loadNextPage(_ request: PaginationMachine.Request, entries: [HomeListEntry], context: SectionFeed.Context) async {
        let page = await SectionCollectionResolver.page(
            entries: entries, from: request.offset, limit: pageSize, context: context
        )
        guard !Task.isCancelled else {
            loads.abandonPage(request)
            return
        }
        guard loads.finishPage(
            request,
            scanned: page.nextOffset - request.offset,
            hasMore: page.hasMoreCandidates
        ) else { return }

        var existing = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { existing.insert($0.id).inserted })
        if page.items.isEmpty, loads.pagination.canLoadMore { requestNextPage() }
    }
}
