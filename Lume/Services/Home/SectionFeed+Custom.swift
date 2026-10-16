import Foundation
import OSLog

extension SectionFeed {
    /// Restore membership before asking any remote service. The ordered input
    /// puts the hero and top rails first; lower rows refresh two at a time.
    func loadCustomSections(cacheKey: String, sections: [CustomHomeSection]) async {
        let request = beginCustomLoad(cacheKey: cacheKey, sections: sections)
        guard !sections.isEmpty else {
            finishCustomLoad(cacheKey: cacheKey, sections: sections, request: request)
            return
        }
        guard context != nil else {
            transition(.finished(.custom, .failed))
            return
        }
        let started = ContinuousClock.now
        // The first row/hero reaches usable content before off-screen matching
        // or network work starts. Other sources have independent tasks.
        if let first = sections.first {
            await loadCustomSection(first, request: request, started: started)
        }
        await withTaskGroup(of: Void.self) { group in
            var remaining = sections.dropFirst().makeIterator()
            for _ in 0 ..< 2 {
                if let section = remaining.next() {
                    group.addTask { await self.loadCustomSection(section, request: request, started: started) }
                }
            }
            for await _ in group {
                guard loadGate.isCurrent(request, for: .custom) else {
                    group.cancelAll()
                    break
                }
                if let section = remaining.next() {
                    group.addTask { await self.loadCustomSection(section, request: request, started: started) }
                }
            }
        }
        finishCustomLoad(cacheKey: cacheKey, sections: sections, request: request)
    }

    func beginCustomLoad(cacheKey: String, sections: [CustomHomeSection]) -> SectionFeedLoadGate.Request {
        let request = loadGate.begin(.custom)
        requestedCustomSections = sections
        let cached = SectionFeedCache.shared.customEntry(surface, for: scoped(cacheKey))
        transition(.began(.custom, key: cacheKey, cache: cached == nil ? .missing : .stale))
        replaceCustomCollections(with: (cached?.value ?? [:]).filter { id, _ in sections.contains { $0.id == id } })
        return request
    }

    func finishCustomLoad(cacheKey: String, sections: [CustomHomeSection], request: SectionFeedLoadGate.Request) {
        guard loadGate.isCurrent(request, for: .custom) else { return }
        transition(.finished(.custom, .loaded))
        let snapshots = Dictionary(uniqueKeysWithValues: sections.compactMap { section in
            collection(for: .custom(section.id)).map { (section.id, $0) }
        })
        SectionFeedCache.shared.storeCustom(surface, key: scoped(cacheKey), collections: snapshots)
    }

    func loadCustomSection(
        _ section: CustomHomeSection, request: SectionFeedLoadGate.Request, started: ContinuousClock.Instant
    ) async {
        let ref = HomeSectionRef.custom(section.id)
        let key = HomeListCacheKey(source: section.sourceURL, account: TraktService.shared.username)
        var step = ContinuousClock.now
        logHeroStep(ref, "lane started", since: started)
        let record = await listCache.record(for: key)
        logHeroStep(ref, "saved list read (\(record.map { "\($0.titles.count) titles" } ?? "none"))", since: step)
        guard customRequestIsCurrent(request, key: key) else { return }
        step = .now
        await restoreMembership(record, for: ref, key: key, request: request, started: started)
        logHeroStep(ref, "saved list matched and published", since: step)
        guard customRequestIsCurrent(request, key: key) else { return }
        transition(.rowBegan(ref, hasCache: collection(for: ref) != nil))
        if heroRef == ref {
            step = .now
            await refreshHeroArtwork()
            logHeroStep(ref, "hero artwork refreshed", since: step)
        }
        guard customRequestIsCurrent(request, key: key) else { return }
        let fresh = record.map { Date.now.timeIntervalSince($0.fetchedAt) < HomeListCache.lifetime } ?? false
        if fresh, canUseMembership(record, for: ref) {
            logHeroStep(ref, "saved list fresh; no network", since: started)
            transition(.rowFinished(ref, .loaded))
            return
        }
        step = .now
        do {
            try await refreshMembership(for: ref, key: key, cached: fresh ? record : nil, request: request, started: started)
            logHeroStep(ref, "network refresh finished", since: step)
        } catch {
            await finishMembershipFailure(error, for: ref, key: key, request: request)
        }
    }

    private func customRequestIsCurrent(_ request: SectionFeedLoadGate.Request, key: HomeListCacheKey) -> Bool {
        loadGate.isCurrent(request, for: .custom) && listAccountIsCurrent(key)
    }

    private func canUseMembership(_ record: HomeListCacheRecord?, for ref: HomeSectionRef) -> Bool {
        guard let snapshot = collection(for: ref) else { return false }
        return snapshot.preview.count >= Self.itemLimit || record?.nextPage == nil
    }

    private func restoreMembership(_ record: HomeListCacheRecord?, for ref: HomeSectionRef, key: HomeListCacheKey,
                                   request: SectionFeedLoadGate.Request, started: ContinuousClock.Instant) async
    {
        guard let record, collection(for: ref) == nil, let context else { return }
        let matching = ContinuousClock.now
        var snapshot = await makeCollection(entries: record.entries, context: context)
        logHeroStep(ref, "catalogue match", since: matching)
        guard customRequestIsCurrent(request, key: key) else { return }
        snapshot.continuation = record.nextPage.map { HomeListContinuation(key: key, page: $0) }
        publishCollection(snapshot, for: ref)
        logCustomReadiness(ref, started: started)
    }

    private func refreshMembership(for ref: HomeSectionRef, key: HomeListCacheKey, cached: HomeListCacheRecord?,
                                   request: SectionFeedLoadGate.Request, started: ContinuousClock.Instant) async throws
    {
        guard let context else { return }
        var entries = cached?.entries ?? []
        var nextPage = cached == nil ? 1 : cached?.nextPage
        while let number = nextPage {
            let page = try await listCache.page(for: key, number: number, fetch: fetchListPage)
            guard customRequestIsCurrent(request, key: key) else { return }
            entries.append(contentsOf: page.entries)
            nextPage = page.nextPage
            guard nextPage.map({ $0 > number && $0 <= 50 }) ?? true else { throw HomeListError.invalidURL }
            var snapshot = await makeCollection(entries: entries, context: context)
            guard customRequestIsCurrent(request, key: key) else { return }
            snapshot.continuation = nextPage.map { HomeListContinuation(key: key, page: $0) }
            await publishMembership(snapshot, for: ref, started: started)
            if snapshot.preview.count >= Self.itemLimit { break }
        }
        guard customRequestIsCurrent(request, key: key) else { return }
        await listCache.store(HomeListPage(entries: entries, nextPage: nextPage), for: key)
        transition(.rowFinished(ref, .loaded))
    }

    private func publishMembership(_ snapshot: SectionCollectionSnapshot, for ref: HomeSectionRef, started: ContinuousClock.Instant) async {
        // A page with more to come is not authoritative: it mustn't shrink the
        // rail already showing (a saved list's 20 titles, say) to its own
        // few, only for the next page to fill it back. An empty page is the
        // same case with nothing shown yet.
        let shown = collection(for: ref)?.preview.count ?? 0
        guard snapshot.continuation == nil || snapshot.preview.count >= max(shown, 1) else { return }
        guard publishCollection(snapshot, for: ref) else { return }
        logCustomReadiness(ref, started: started)
        if heroRef == ref { await refreshHeroArtwork() }
    }

    private func finishMembershipFailure(_ error: Error, for ref: HomeSectionRef, key: HomeListCacheKey, request: SectionFeedLoadGate.Request) async {
        guard customRequestIsCurrent(request, key: key) else { return }
        if let failure = error as? HomeListError,
           failure == .privateList || failure == .listNotShared || failure == .listNotFound
        {
            await listCache.remove(key)
            guard customRequestIsCurrent(request, key: key) else { return }
            publishCollection(.empty, for: ref)
            transition(.rowFinished(ref, .failed))
            return
        }
        let hasCache = collection(for: ref) != nil
        if !hasCache { publishCollection(.empty, for: ref) }
        transition(.rowFinished(ref, hasCache ? .loaded : .failed))
        Logger.network.warning("Custom list refresh failed; cached membership retained: \(error.localizedDescription, privacy: .private)")
    }

    func listAccountIsCurrent(_ key: HomeListCacheKey) -> Bool {
        key == HomeListCacheKey(source: key.source, account: TraktService.shared.username)
    }

    /// Diagnostic timing for the hero's lane only, so a cold launch shows
    /// which step holds the first screen back.
    private func logHeroStep(_ ref: HomeSectionRef, _ step: String, since start: ContinuousClock.Instant) {
        guard heroRef == ref else { return }
        Logger.home.info("\(surface.rawValue) hero lane: \(step, privacy: .public) — \(String(describing: start.duration(to: .now)), privacy: .public)")
    }

    private func logCustomReadiness(_ ref: HomeSectionRef, started: ContinuousClock.Instant) {
        guard let snapshot = collection(for: ref) else { return }
        logMatch("custom list", snapshot)
        Logger.home.info("\(surface.rawValue) row \(ref.token, privacy: .public) ready after \(String(describing: started.duration(to: .now)), privacy: .public); hero=\(heroRef == ref)")
    }
}
