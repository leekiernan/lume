//
//  TVGameDetailView.swift
//  Lume
//
//  The pushed tvOS Match Centre a fixture card or hero opens. It follows the
//  `EPGProgramDetailView.tvBody` conventions — a fixed 10-foot layout sized in
//  explicit points, with native NavigationStack Back handling and
//  the focusable actions kept above the long non-focusable content so the focus
//  engine can always reach them. It shows a two-colour team gradient header with
//  the score or kickoff, the channels the fixture resolved to in the viewer's own
//  playlists (one confident channel becomes a single prominent Watch button), the
//  Timeline / Stats / Lineup pill tabs fed off-main by the `SportsDataProvider`,
//  and league standings highlighting both opponents, with followed-team stars.
//
//  `TVChannelRow` in LiveTVTVComponents is `private` and modelled on a
//  `LiveStream` + `ChannelEPG`, so it cannot carry a `ResolvedChannel`'s quality
//  badge and matched-programme line; this screen uses a purpose-built focusable
//  channel row instead. The Timeline / Stats / Lineup renderers in
//  GameDetailSections are likewise `private` and sized for the phone, so the tabs
//  here render tvOS-scaled variants rather than reaching into that file.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    struct TVGameDetailView: View {
        let route: SportsMatchRoute
        var provider: any SportsDataProvider = ESPNClient.shared

        @Environment(\.modelContext) private var modelContext
        @Environment(\.contentRestriction) private var restriction
        @State private var follows = SportsFollowService.shared
        @State private var store = SportsStore.shared
        @State private var detailLoad = SportsEventDetailLoadMachine()
        @State private var fetchedStandings: [SportsStandingRow] = []
        @State private var tab: GameDetailTab = .timeline
        @State private var resolution = SportsFixtureResolutionMachine()
        @State private var playingMedia: PlayableMedia?
        private typealias FocusTarget = SportsDetailFocusTarget<GameDetailTab>

        @FocusState private var focus: FocusTarget?
        /// Which column holds focus, wherever in it: most of the left column's
        /// blocks (markets, timeline, table) aren't `focus` targets.
        @FocusedValue(\.matchCentreColumn) private var focusedColumn
        @AppStorage(SportsSyncService.hideScoresKey) private var hideScoresSetting = false
        @State private var reveal = SportsScoreReveal.shared

        private var fixture: SportsFixture {
            route.currentFixture(in: store.snapshot(for: route.fixture.leagueId)?.fixtures ?? [])
        }

        private var resolved: [ResolvedChannel] {
            route.channels(visibleUnder: restriction.visibilityToken)
        }

        private var defaultFocus: FocusTarget {
            .preferred(
                channelID: fixture.status.state == .final ? nil : channels.first?.id,
                teamID: (fixture.home?.team ?? fixture.away?.team)?.id,
                availableTabs: detailLoad.detail?.availableTabs(hidingScores: hidesScores) ?? [],
                selectedTab: tab
            )
        }

        /// Hide Scores, unless this one game has been revealed.
        private var hidesScores: Bool {
            !fixture.showsScore(hidingScores: hideScoresSetting, reveal: reveal)
        }

        /// The resolver's channels, ordered within each tier for this viewer's
        /// languages and screen (`SportsChannelPreference`).
        private var channels: [ResolvedChannel] {
            let fetched = resolution.resolved(for: restriction.visibilityToken)[fixture.id] ?? []
            return SportsChannelPreference.ordered(resolved.isEmpty ? fetched : resolved, context: .current)
        }

        var body: some View {
            Group {
                if fixture.status.state == .final {
                    // Nothing left to watch: the visuals take the whole width.
                    detailScroll.frame(maxWidth: 1500).frame(maxWidth: .infinity)
                } else {
                    // Channels get their own scrolling column, so a long list
                    // never pushes the score, tabs and table below the fold.
                    HStack(alignment: .top, spacing: 60) {
                        detailScroll
                        watchSection.frame(width: Self.channelColumnWidth)
                    }
                }
            }
            .padding(.horizontal, 90)
            // The best channel takes focus on arrival. Coming down from the tab
            // bar is left to geometry, so it lands on the score at the top.
            .tvDetailDefaultFocus($focus, defaultFocus, priority: .automatic)
            .background(background.ignoresSafeArea())
            // The detail stays pushed beneath its player, just like movies
            // and series: no closing cover to race against the stream open.
            .fullScreenCover(item: $playingMedia) { media in
                FullScreenPlayerView(media: media)
            }
            .task(id: [fixture.id, restriction.visibilityToken]) {
                await loadDetail()
            }
            .onAppear { SportsSyncService.shared.beginLivePolling() }
            .onDisappear { SportsSyncService.shared.endLivePolling() }
        }

        private static let channelColumnWidth: CGFloat = 520

        /// Once the header scrolls off, the tab bar is closer than its buttons,
        /// so "up" leaves the column without bringing the score back. Leaving
        /// the column (for the tab bar or the channels) scrolls it to the top,
        /// and reaching the tabs or the header scrolls back as far as the score.
        private var detailScroll: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 48) {
                        header.id(ScrollAnchor.header)
                        if let bouts = fixture.bouts, !bouts.isEmpty {
                            TVFightCardSection(bouts: bouts, hidesScores: hidesScores)
                        }
                        if let circuit = RaceCircuitSummary(fixture: fixture) {
                            TVRaceCircuitSection(summary: circuit, hidesScores: hidesScores)
                        }
                        TVGameDetailMarkets(detail: detailLoad.detail, fixture: fixture, hidesScores: hidesScores)
                        detailTabsSection
                        standingsSection
                        if fixture.sport == "racing", !hidesScores {
                            TVRacingSeasonSection(fixture: fixture)
                        }
                    }
                    .padding(.vertical, 70)
                }
                .scrollClipDisabled()
                .focusSection()
                .focusedValue(\.matchCentreColumn, .details)
                .onChange(of: focusedColumn) { old, new in
                    guard old == .details, new != .details else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(ScrollAnchor.header, anchor: .top) }
                }
                .onChange(of: focus) { _, target in
                    let anchor: (ScrollAnchor, UnitPoint)? = switch target {
                    case .summary, .follow: (.header, .top)
                    case .tab: (.tabs, .bottom)
                    default: nil
                    }
                    guard let anchor else { return }
                    // After the focus engine's own scroll for this move.
                    Task { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(anchor.0, anchor: anchor.1) } }
                }
            }
        }

        private enum ScrollAnchor { case header, tabs }

        /// The team tints are translucent washes over a solid detail backdrop.
        private var background: some View {
            ZStack {
                Color(white: 0.08)
                TeamPalette.gradient(home: fixture.homePalette, away: fixture.awayPalette)
            }
        }

        // MARK: - Header

        /// A team match's header holds its own focus targets, the Follow
        /// buttons. Only an event without teams makes the whole header one
        /// landing: `.focusable(false)` on it would shut the buttons out too.
        @ViewBuilder
        private var header: some View {
            if fixture.hasTeams {
                headerContent
            } else {
                headerContent.focusable().focused($focus, equals: .summary)
            }
        }

        private var headerContent: some View {
            VStack(spacing: 24) {
                TVMatchCentreLeagueLine(fixture: fixture)
                if fixture.hasTeams {
                    // One focus section, so "up" from the centred tabs reaches
                    // the Follow buttons under each team instead of passing
                    // between them; left and right move from one to the other.
                    matchup.focusSection()
                } else {
                    eventHeader
                }
            }
            // A UFC/racing event without channels or tabs is still a pushed
            // detail screen. Keep a real landing here so focus (and native Back)
            // stays inside its NavigationStack instead of falling to the app tab.
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(focus == .summary ? 0.14 : 0))
                    .padding(-24)
            }
            .animation(.easeOut(duration: 0.15), value: focus == .summary)
        }

        private var matchup: some View {
            HStack(alignment: .top, spacing: 48) {
                if let home = fixture.home {
                    teamColumn(home)
                } else {
                    Spacer().frame(maxWidth: .infinity)
                }
                centerStatus.frame(width: 320)
                if let away = fixture.away {
                    teamColumn(away)
                } else {
                    Spacer().frame(maxWidth: .infinity)
                }
            }
        }

        private var eventHeader: some View {
            VStack(spacing: 16) {
                if let kind = fixture.sessionKind {
                    Text(kind.displayName)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                    Text(verbatim: fixture.eventTitle)
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                } else {
                    Text(verbatim: fixture.eventTitle)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if let subtitle = fixture.eventSubtitle {
                        Text(verbatim: subtitle)
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                if fixture.sessions.isEmpty || fixture.status.state != .scheduled {
                    centerStatus
                }
                if !fixture.sessions.isEmpty {
                    sessionList
                }
            }
        }

        @ViewBuilder
        private var centerStatus: some View {
            switch fixture.status.state {
            case .final:
                VStack(spacing: 10) {
                    scoreText
                    if !hidesScores {
                        TVSetsLine(fixture: fixture)
                    }
                    EndedBadge(fontSize: 22)
                    if !hidesScores, let qualifier = fixture.status.localizedEndingQualifier(family: fixture.periodFamily) {
                        Text(verbatim: qualifier)
                            .font(.system(size: 26)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            case .inProgress:
                VStack(spacing: 10) {
                    scoreText
                    if !hidesScores {
                        TVSetsLine(fixture: fixture)
                    }
                    LiveBadge(fontSize: 22)
                    if let line = fixture.status.liveDetail(family: fixture.periodFamily, hidingScores: hidesScores) {
                        Text(verbatim: line)
                            .font(.system(size: 26)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            case .scheduled, .postponed:
                VStack(spacing: 8) {
                    Text(fixture.headlineDate, format: fixture.startTimeIsTentative == true
                        ? .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                        : .dateTime.hour().minute())
                        .font(.system(size: 60, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(verbatim: fixture.kickoffDayText())
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }

        @ViewBuilder
        private var scoreText: some View {
            if fixture.hasTeams, !hidesScores {
                Text(verbatim: fixture.scoreLine)
                    .font(.system(size: fixture.hasTextScores ? 48 : 80, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
            }
        }

        private func followButton(_ team: SportsTeam) -> some View {
            let following = follows.isFollowing(team.id)
            return Button {
                follows.toggle(team.id, kind: .team)
            } label: {
                // The hub's pill chrome: solid white on focus. A fixed
                // capsule left a focused "Follow" looking unfocused.
                TVSportsPillChrome {
                    Label(following ? "Following" : "Follow", systemImage: following ? "star.fill" : "star")
                        .font(.system(size: 24, weight: .semibold))
                }
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
            .focused($focus, equals: .follow(team.id))
            .accessibilityLabel(following ? Text("Unfollow \(team.name)") : Text("Follow \(team.name)"))
            .padding(.top, 6)
        }

        // MARK: - Watch

        /// The right-hand column: every channel, best first, scrolling on its
        /// own as focus moves down it while the match stays in view.
        private var watchSection: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("On Your Channels")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    VStack(spacing: 16) {
                        switch channels.count {
                        case 0:
                            emptyChannels
                        case 1:
                            singleChannel(channels[0])
                        default:
                            ForEach(channels) { channelRow($0) }
                        }
                    }
                    // Room for the focus zoom inside the clipped column.
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                }
                .padding(.horizontal, -14)
            }
            .padding(.vertical, 70)
            .focusSection()
            .focusedValue(\.matchCentreColumn, .channels)
        }

        private var emptyChannels: some View {
            SportsEmptyChannelsView()
        }

        private func singleChannel(_ channel: ResolvedChannel) -> some View {
            Button {
                watch(channel)
            } label: {
                HStack(spacing: 22) {
                    ChannelLogo(urlString: channel.stream.streamIcon, size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        TVSportsChannelName(channel: channel, size: 30)
                        TVSportsChannelSubtitle(channel: channel, size: 24)
                    }
                    Spacer(minLength: 16)
                    Label("Watch", systemImage: "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }
            .buttonStyle(TVGlassButtonStyle())
            .focused($focus, equals: .channel(channel.id))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Watch on \(channel.stream.name)"))
        }

        private func channelRow(_ channel: ResolvedChannel) -> some View {
            TVSportsChannelRow(channel: channel, onPlay: { watch(channel) })
                .focused($focus, equals: .channel(channel.id))
        }

        private func watch(_ channel: ResolvedChannel) {
            playingMedia = SportsPlayback.media(for: channel, in: modelContext)
        }

        // MARK: - Tabs

        @ViewBuilder
        private var detailTabsSection: some View {
            if let eventDetail = detailLoad.detail, eventDetail.hasTabContent(hidingScores: hidesScores) {
                VStack(spacing: 28) {
                    tabPills(for: eventDetail)
                        // Scroll to the controls, never the bottom of the
                        // selected tab's potentially screenfuls of content.
                        .id(ScrollAnchor.tabs)
                    tabContent(eventDetail)
                }
            } else if detailLoad.isLoading, expectsEventDetail {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
        }

        private func tabPills(for detail: SportsEventDetail) -> some View {
            let tabs = detail.availableTabs(hidingScores: hidesScores)
            return HStack(spacing: 12) {
                ForEach(tabs) { value in
                    TVTabPill(title: value.title, isActive: tab == value) { tab = value }
                        .focused($focus, equals: .tab(value))
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.08)))
            .focusSection()
            .onAppear {
                if !tabs.contains(tab), let first = tabs.first {
                    tab = first
                }
            }
        }

        private func tabContent(_ detail: SportsEventDetail) -> some View {
            TVDetailTabContent(detail: detail, fixture: fixture, tab: tab, hidesScores: hidesScores)
        }

        // MARK: - Standings

        @ViewBuilder
        private var standingsSection: some View {
            let rows = standingsRows
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Table")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                    let groups = SportsStandingRow.grouped(rows)
                    ForEach(groups) { group in
                        if groups.count > 1, let title = group.title {
                            title
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 12)
                        }
                        // Focus, not touch, scrolls a tvOS ScrollView: a 32-row table
                        // as one focusable block would leave its tail unreachable, so
                        // it is dealt out in screen-sized focusable chunks.
                        VStack(spacing: 4) {
                            ForEach(Array(group.rows.chunked(into: Self.standingsChunk).enumerated()), id: \.offset) { index, chunk in
                                StandingsTable(
                                    rows: chunk, followedTeamIds: follows.followedKeys,
                                    playingTeamIds: fixture.standingsTeamIds, showsHeader: index == 0
                                )
                                .tvFocusBlock()
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.06)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private static let standingsChunk = 8

        private var standingsRows: [SportsStandingRow] {
            let cached = store.snapshot(for: fixture.leagueId)?.standings ?? []
            return cached.isEmpty ? fetchedStandings : cached
        }
    }

    private extension TVGameDetailView {
        // MARK: - Loading

        private func loadDetail() async {
            guard let league = SportsCatalog.league(id: fixture.leagueId) else { return }
            let detailRequest = detailLoad.begin()

            if resolved.isEmpty, fixture.status.state != .final {
                await SportsFixtureResolution.run(
                    $resolution, fixtures: [fixture],
                    container: modelContext.container,
                    restriction: restriction, soonestFirst: false
                )
                guard !Task.isCancelled else { return }
            }
            if store.snapshot(for: fixture.leagueId)?.standings.isEmpty ?? true, fetchedStandings.isEmpty {
                let standings = await (try? provider.standings(league: league)) ?? []
                guard !Task.isCancelled else { return }
                fetchedStandings = standings
            }
            do {
                let detail = try await provider.eventDetail(league: league, fixture: fixture)
                guard !Task.isCancelled else { return }
                detailLoad.finish(detailRequest, detail: detail)
            } catch {
                guard !Task.isCancelled else { return }
                detailLoad.fail(detailRequest)
            }
        }

        private var expectsEventDetail: Bool {
            fixture.status.state == .inProgress || fixture.status.state == .final
        }

        // MARK: - Derived
    }

    enum MatchCentreColumn: Hashable { case details, channels }

    extension FocusedValues {
        @Entry var matchCentreColumn: MatchCentreColumn?
    }

    /// The header's per-team column, kept out of the struct body for length.
    extension TVGameDetailView {
        /// A race weekend's timetable: every session with its day and time.
        private var sessionList: some View {
            VStack(spacing: 6) {
                ForEach(Array(fixture.sessions.enumerated()), id: \.offset) { _, session in
                    let isCurrent = session.kind == fixture.sessionKind
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.kind.displayName)
                                .font(.system(size: 28, weight: isCurrent ? .bold : .medium))
                                .foregroundStyle(isCurrent ? .white : .white.opacity(0.85))
                            if !hidesScores, let podium = session.podiumLine {
                                Text(verbatim: podium)
                                    .font(.system(size: 21))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        Spacer()
                        Text(session.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(session.date, format: .dateTime.hour().minute())
                            .font(.system(size: 28, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(minWidth: 110, alignment: .trailing)
                    }
                    .tvFocusRow()
                }
            }
            .frame(maxWidth: 900)
            .padding(.top, 8)
        }

        /// A finished game's record and form already count its result.
        private var showsRecordAndForm: Bool {
            fixture.showsForm(hidingScores: hidesScores)
        }

        private func teamColumn(_ competitor: SportsCompetitor) -> some View {
            VStack(spacing: 14) {
                TeamCrest(team: competitor.team, size: 130)
                    .accessibilityHidden(true)
                Text(verbatim: competitor.team.name)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if showsRecordAndForm {
                    if let record = competitor.record, !record.isEmpty {
                        Text(verbatim: record)
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if let form = fixture.headerForm(for: competitor, detail: detailLoad.detail) {
                        TeamFormLine(content: form, letterSize: 20, textColor: .white.opacity(0.6))
                    }
                }
                followButton(competitor.team)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
#endif
