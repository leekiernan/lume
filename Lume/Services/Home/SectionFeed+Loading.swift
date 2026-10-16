import Foundation

extension SectionFeed {
    private struct LoadPass {
        let plan: SectionFeedLoadPlan
        let keys: SectionFeedLoadKeys
        let traktKey: String
        let simklKey: String
        let customRequest: SectionFeedLoadGate.Request?
        let started: ContinuousClock.Instant
    }

    /// Installs the plan before context recovery. This page-level coordinator
    /// owns every required reload; independent legacy callers retain recovery.
    func configure(plan: SectionFeedLoadPlan, context: Context) {
        loadPlan = plan
        heroLoadStarted = .now
        update(context: context)
        for source in SectionFeedSource.allCases where !plan.requests(source) {
            loadGate.cancel(source)
            transition(.skipped(source))
        }
        for ref in collections.keys where !plan.rows.contains(ref) {
            removeCollection(for: ref)
        }
    }

    /// Bounded, layout-ordered work: hero and the leading remote rail get the
    /// first two slots. No delay, viewport task or global readiness barrier.
    func load(plan: SectionFeedLoadPlan, keys: SectionFeedLoadKeys, traktKey: String, simklKey: String) async {
        let customRequest = plan.requests(.custom) ? beginCustomLoad(cacheKey: keys.customCache, sections: plan.customSections) : nil
        let pass = LoadPass(plan: plan, keys: keys, traktKey: traktKey, simklKey: simklKey, customRequest: customRequest, started: .now)
        await withTaskGroup(of: Void.self) { group in
            var remaining = plan.jobs.makeIterator()
            for _ in 0 ..< 2 {
                if let row = remaining.next() {
                    group.addTask { await self.load(row: row, pass: pass) }
                }
            }
            for await _ in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if let row = remaining.next() {
                    group.addTask { await self.load(row: row, pass: pass) }
                }
            }
        }
        if let customRequest { finishCustomLoad(cacheKey: keys.customCache, sections: plan.customSections, request: customRequest) }
    }

    private func load(row: HomeSectionRef, pass: LoadPass) async {
        guard !Task.isCancelled else { return }
        switch SectionFeedSource(row: row) {
        case .trending:
            let rows = pass.plan.rows.filter { SectionFeedSource(row: $0) == .trending }.map(\.token).sorted().joined(separator: ",")
            await loadTrending(cacheKey: "\(pass.keys.catalog)-\(rows)")
        case let .watchlist(provider): await loadWatchlist(provider, cacheKey: provider == .trakt ? pass.traktKey : pass.simklKey)
        case .custom:
            if let request = pass.customRequest, let section = pass.plan.customSections.first(where: { .custom($0.id) == row }) {
                await loadCustomSection(section, request: request, started: pass.started)
            }
        case nil: break
        }
    }
}
