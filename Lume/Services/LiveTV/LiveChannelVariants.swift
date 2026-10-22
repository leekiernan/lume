//
//  LiveChannelVariants.swift
//  Lume
//
//  One channel listed in several qualities ("Sky Sports F1 UHD", "… FHD",
//  "… HD", "… SD") is one row in the browse lists, the way `TitleSources`
//  makes the copies of a film one title. The qualities are found by name
//  (`ChannelQuality.parse`), once per import, and stored on the rows:
//
//  - `variantKey` on every member, which the player's Source menu and the
//    choice of what plays look the others up by, across categories;
//  - `isVariantFollower` on all but one member per category, which the list
//    queries skip, so the work stays in SQL and surfing's positional reads
//    keep working;
//  - `variantQualities` for the row's badge.
//
//  Measured on a 9,899-channel provider list: the guide id is no grouping key.
//  It is missing on 83% of channels, joins different stations a provider gave
//  one id (PBS affiliates, East and West feeds, HBO and HBO2), and differs
//  between real qualities of one channel (RTÉ One HD and FHD). Names grouped
//  245 channels into 94 channels with nothing wrongly joined, once a
//  bracketed region after the tag stayed in the key.
//
//  A channel with one quality gets nothing written: the defaults are its
//  values, so grouping costs nothing for the channels it doesn't touch.
//

import Foundation
import OSLog
import SwiftData

nonisolated enum LiveChannelVariants {
    /// Bumped when the grouping rules change, so the launch backfill regroups
    /// stores grouped under the old ones.
    static let version = 1

    struct Member {
        let id: String
        let name: String
        let categoryID: String?
        let num: Int
        let isHidden: Bool
    }

    struct Assignment: Equatable {
        var key: String?
        var isFollower = false
        var qualities: String?

        static let none = Assignment()
    }

    /// What each grouped member should hold, by id. Members missing from the
    /// result belong to no group.
    ///
    /// A group is the channels sharing a name key that differ by their quality
    /// tag. Within a category, two members with the same tag — exact repeats
    /// like a provider's "US|NFHS LIVE - Newark" event feeds, or "Brazzers"
    /// and "BRAZZERS" — are separate listings, not qualities, so that category
    /// keeps all of its copies apart. Hidden channels are left out: hiding one
    /// quality removes it from the choice, and a hidden member must never be
    /// the one row standing for the rest.
    static func assignments(for members: [Member]) -> [String: Assignment] {
        let parsed = members.filter { !$0.isHidden }.compactMap { member -> (Member, ChannelQuality.Parsed)? in
            let result = ChannelQuality.parsed(member.name)
            return result.key.isEmpty ? nil : (member, result)
        }
        let buckets = Dictionary(grouping: parsed) { BucketKey(category: $0.0.categoryID, key: $0.1.key) }
        let listings = buckets.values.filter { bucket in
            Set(bucket.map(\.1.tagIdentity)).count == bucket.count
        }
        let groups = Dictionary(grouping: listings.joined()) { $0.1.key }

        var result: [String: Assignment] = [:]
        for (key, group) in groups where Set(group.map(\.1.tagIdentity)).count > 1 {
            let qualities = badge(group.map(\.1.quality))
            for category in Dictionary(grouping: group, by: { $0.0.categoryID }).values {
                let lead = category.min { precedes($0.0, $1.0) }?.0.id
                for (member, _) in category {
                    result[member.id] = Assignment(key: key, isFollower: member.id != lead, qualities: qualities)
                }
            }
        }
        return result
    }

    private struct BucketKey: Hashable {
        let category: String?
        let key: String
    }

    /// The provider's order: the row that stands for a category's qualities is
    /// the one the provider listed first.
    private static func precedes(_ lhs: Member, _ rhs: Member) -> Bool {
        if lhs.num != rhs.num { return lhs.num < rhs.num }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id < rhs.id
    }

    static func badge(_ qualities: [ChannelQuality?]) -> String {
        Set(qualities.map { $0 ?? .sd }).sorted(by: >).map(\.label).joined(separator: " · ")
    }

    // MARK: - Writing

    /// Regroups one playlist's channels, writing only rows whose grouping
    /// changed. Runs after every live import and from the launch backfill, on
    /// a context of its own.
    static func reconcile(playlistID: UUID, container: ModelContainer) {
        let prefix = playlistID.uuidString
        let interval = Perf.begin(.groupLiveVariants)
        defer { Perf.end(interval) }
        autoreleasepool {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            guard let streams = try? context.fetch(FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id.starts(with: prefix) })) else {
                return
            }
            let assignments = assignments(for: streams.map {
                Member(id: $0.id, name: $0.name, categoryID: $0.categoryId, num: $0.num, isHidden: $0.isHidden)
            })
            var changed = 0
            for stream in streams {
                let wanted = assignments[stream.id] ?? .none
                guard stream.variantKey != wanted.key || stream.isVariantFollower != wanted.isFollower
                    || stream.variantQualities != wanted.qualities else { continue }
                stream.variantKey = wanted.key
                stream.isVariantFollower = wanted.isFollower
                stream.variantQualities = wanted.qualities
                changed += 1
            }
            if context.hasChanges { try? context.save() }
            let grouped = assignments.count
            Logger.database.info("Live variants: \(grouped) of \(streams.count) channels grouped, \(changed) rows changed")
        }
        stamp(playlistID)
    }

    /// Groups every playlist not yet grouped under this `version`: stores from
    /// before grouping, and ones grouped under older rules. An import regroups
    /// its playlist anyway; this covers the playlists that don't sync for a
    /// while.
    @concurrent
    static func backfill(container: ModelContainer, defaults: UserDefaults = .standard) async {
        let playlists = autoreleasepool {
            ((try? ModelContext(container).fetch(FetchDescriptor<Playlist>())) ?? []).map(\.id)
        }
        for playlist in playlists where defaults.integer(forKey: stampKey(playlist)) != version {
            guard !Task.isCancelled else { return }
            reconcile(playlistID: playlist, container: container)
        }
    }

    private static func stampKey(_ playlistID: UUID) -> String {
        "liveVariants.version.\(playlistID.uuidString)"
    }

    private static func stamp(_ playlistID: UUID, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: stampKey(playlistID))
    }
}

// MARK: - Choosing a quality

nonisolated extension LiveChannelVariants {
    /// Whether this screen is 4K. Only tvOS reports a TV's resolution; set
    /// once at launch on the main actor, read wherever a channel is tuned.
    nonisolated(unsafe) static var displayIs4K = false

    /// What tuning `stream` plays, and the row it plays for.
    struct Tuning {
        let play: LiveStream
        /// The row standing for the channel in `stream`'s category.
        let anchorID: String?
    }

    /// The quality a grouped channel opens in: the one the viewer watched
    /// last — the remembered pick, as the copy watched last is for a film
    /// (`TitleSources.preferred`) — else the best fit for the screen.
    ///
    /// Tuning has no viewer restriction to hand, so it only picks among
    /// qualities in categories that are neither hidden nor restricted. One in
    /// a restricted category is still in the Source menu for whoever may see it.
    static func tuning(_ stream: LiveStream, playlist: Playlist) -> Tuning {
        guard let context = stream.modelContext else { return Tuning(play: stream, anchorID: nil) }
        let members = members(of: stream, prefix: playlist.contentIDPrefix, in: context)
        let blocked = blockedCategories(of: members, in: context)
        let candidates = members.filter { $0.id == stream.id || !blocked.contains($0.categoryId ?? "") }
        let anchor = candidates.first { $0.categoryId == stream.categoryId && !$0.isVariantFollower }?.id ?? stream.id
        let watched = candidates.filter { $0.lastWatchedDate != nil }
        let pick = watched.max { ($0.lastWatchedDate ?? .distantPast) < ($1.lastWatchedDate ?? .distantPast) }
            ?? ranked(candidates).first
            ?? stream
        return Tuning(play: pick, anchorID: anchor)
    }

    /// Every visible quality of `stream`'s channel in its playlist, `stream`
    /// included even when hidden (it is what was asked for).
    static func members(of stream: LiveStream, prefix: String, in context: ModelContext) -> [LiveStream] {
        guard let key = stream.variantKey else { return [stream] }
        let descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate {
            $0.variantKey == key && $0.id.starts(with: prefix) && $0.isHidden == false
        })
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.contains { $0.id == stream.id } ? rows : [stream] + rows
    }

    private static func blockedCategories(of members: [LiveStream], in context: ModelContext) -> Set<String> {
        let ids = Array(Set(members.compactMap(\.categoryId)))
        let categories = (try? context.fetch(FetchDescriptor<Category>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        return Set(categories.filter { $0.isHidden || $0.isRestricted }.map(\.id))
    }

    /// Best for this screen first: the quality that fits it, then a 50/60 fps
    /// feed over the same quality without, then the provider's order.
    static func ranked(_ streams: [LiveStream]) -> [LiveStream] {
        streams.map { (stream: $0, rank: rank(ChannelQuality.parsed($0.name))) }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
                if lhs.stream.num != rhs.stream.num { return lhs.stream.num < rhs.stream.num }
                return lhs.stream.id < rhs.stream.id
            }
            .map(\.stream)
    }

    /// Fit for the screen, doubled, plus one for a high frame rate. On a
    /// 1080p screen FHD beats UHD, which only costs bandwidth and start-up
    /// time; an untagged name is usually the provider's HD feed.
    static func rank(_ parsed: ChannelQuality.Parsed) -> Int {
        let fit = switch parsed.quality {
        case .uhd: displayIs4K ? 4 : 1
        case .fhd: displayIs4K ? 3 : 4
        case .hd: 2
        case nil: displayIs4K ? 1 : 2
        case .sd: 0
        }
        return fit * 2 + (parsed.isHighFrameRate ? 1 : 0)
    }
}

nonisolated extension LiveChannelVariants {
    /// The quality just below `current` among `others`: the best of those
    /// below it, a high frame rate counting above the same quality without.
    /// An untagged name counts as HD, the provider's usual base feed.
    static func stepDown(from current: LiveStream, among others: [LiveStream]) -> LiveStream? {
        func level(_ stream: LiveStream) -> Int {
            let parsed = ChannelQuality.parsed(stream.name)
            let quality = switch parsed.quality ?? .hd {
            case .sd: 0
            case .hd: 1
            case .fhd: 2
            case .uhd: 3
            }
            return quality * 2 + (parsed.isHighFrameRate ? 1 : 0)
        }
        let ceiling = level(current)
        return others.filter { level($0) < ceiling }.max { level($0) < level($1) }
    }
}

extension ChannelQuality.Parsed {
    var isHighFrameRate: Bool {
        guard let tag else { return false }
        return tag.uppercased().replacing(" ", with: "").contains(/[56]0FPS/)
    }
}

extension ChannelQuality {
    var label: String {
        switch self {
        case .sd: "SD"
        case .hd: "HD"
        case .fhd: "FHD"
        case .uhd: "UHD"
        }
    }
}
