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
    @State private var pagination = PaginationMachine()
    @State private var loadingCredits = true
    /// The `loadKey` whose credits are in `entries`. `.task` restarts when a
    /// covered page reappears, and a fetch cut short by that must run again.
    @State private var loadedKey: String?

    private let pageSize = 100

    #if os(tvOS)
        private let headshotSize: CGFloat = TVDetailMetrics.castAvatar
        private let headshotImageSize = "w342"
    #else
        private let headshotSize: CGFloat = 112
        private let headshotImageSize = "w185"
    #endif

    var body: some View {
        CategoryPage(title: route.name) {
            headshot
            CollectionGridContent(
                items: items,
                isLoading: loadingCredits || pagination.isLoading,
                isLoadingMore: pagination.isLoading,
                emptyMessage: Text("None of \(route.name)'s films or series are in this playlist."),
                animationNamespace: animationNamespace,
                onReachEnd: requestNextPage
            )
        }
        .task(id: loadKey) { await load() }
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
        guard loadedKey != key else { return }
        loadingCredits = true
        entries = []
        items = []
        let remote = await PersonCreditsStore.shared.credits(for: route.personID)
        guard !Task.isCancelled, key == loadKey else { return }
        entries = remote ?? PersonFilmography.localEntries(personID: route.personID, in: modelContext)
        loadedKey = key
        pagination.prepare(for: key)
        pagination.seed(nextOffset: 0, canLoadMore: !entries.isEmpty)
        loadingCredits = false
        requestNextPage()
    }

    private func requestNextPage() {
        guard pagination.canLoadMore, !pagination.isLoading else { return }
        Task { await loadNextPage() }
    }

    private func loadNextPage() async {
        guard let request = pagination.beginLoading() else { return }
        let page = await SectionCollectionResolver.page(
            entries: entries, from: request.offset, limit: pageSize, context: feedContext
        )
        guard !Task.isCancelled else {
            pagination.abandon(request)
            return
        }
        guard pagination.finish(
            request,
            scanned: page.nextOffset - request.offset,
            hasMore: page.hasMoreCandidates
        ) else { return }

        var existing = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { existing.insert($0.id).inserted })
        if page.items.isEmpty, pagination.canLoadMore { requestNextPage() }
    }
}
