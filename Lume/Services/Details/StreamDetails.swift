//
//  StreamDetails.swift
//  Lume
//
//  What a copy's stream is, for the Source list: resolution, HDR, frame rate,
//  codecs, audio layout and bitrate. Read from the provider's ffprobe block
//  (`get_vod_info`, Xtream movies) when the list opens; otherwise, and until it
//  arrives, from the tags providers put in stream names ("4K", "HDR", "HEVC",
//  "Atmos", "MULTI").
//

import Foundation
import SwiftData

nonisolated struct StreamDetails: Equatable {
    nonisolated enum Resolution: Int, Comparable {
        case standard, hd720, fullHD, uhd

        /// From a frame's size; a cropped widescreen frame is shorter than
        /// its class, so width counts as much as height.
        init?(width: Int?, height: Int?) {
            let width = width ?? 0, height = height ?? 0
            guard width > 0 || height > 0 else { return nil }
            if width >= 3200 || height >= 2000 {
                self = .uhd
            } else if width >= 1800 || height >= 1000 {
                self = .fullHD
            } else if width >= 1200 || height >= 700 {
                self = .hd720
            } else {
                self = .standard
            }
        }

        var label: String {
            switch self {
            case .uhd: "4K"
            case .fullHD: "1080p"
            case .hd720: "720p"
            case .standard: "SD"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Audio channels as a layout: 2 is stereo, 6 is 5.1, 8 is 7.1.
    nonisolated struct AudioLayout: Equatable {
        let channels: Int

        var label: String {
            switch channels {
            case 1: "Mono"
            case 2: "Stereo"
            case 6: "5.1"
            case 8: "7.1"
            default: String(localized: "\(channels) ch", comment: "An audio layout by channel count, e.g. \"3 ch\"")
            }
        }
    }

    var resolution: Resolution?
    var runtime: MediaRuntime?
    var isHDR = false
    /// Frames per second, e.g. 23.976.
    var frameRate: Double?
    var videoCodec: String?
    var audioCodec: String?
    var audioLayout: AudioLayout?
    /// Kilobits per second.
    var bitrate: Int?
    /// Name-only tags with no field of their own: "Dolby Vision", "Atmos",
    /// "MULTI".
    var tags: [String] = []

    /// The fields the provider measured, over whatever the name claimed.
    func merging(_ measured: StreamDetails) -> StreamDetails {
        var merged = self
        merged.resolution = measured.resolution ?? resolution
        merged.runtime = measured.runtime ?? runtime
        merged.isHDR = measured.isHDR || isHDR
        merged.frameRate = measured.frameRate ?? frameRate
        merged.videoCodec = measured.videoCodec ?? videoCodec
        merged.audioCodec = measured.audioCodec ?? audioCodec
        merged.audioLayout = measured.audioLayout ?? audioLayout
        merged.bitrate = measured.bitrate ?? bitrate
        return merged
    }

    /// The row's detail line, most telling first: "4K · HDR · HEVC ·
    /// 23.976 fps · 5.1 · 12.4 Mbps".
    var summary: [String] {
        var items: [String] = []
        if let resolution { items.append(resolution.label) }
        if isHDR { items.append("HDR") }
        items += tags
        if let videoCodec { items.append(videoCodec) }
        if let frameRate {
            items.append(String(localized: "\(frameRate.formatted(.number.precision(.fractionLength(0 ... 3)))) fps",
                                comment: "A video frame rate, e.g. \"23.976 fps\""))
        }
        if let audioLayout { items.append([audioCodec, audioLayout.label].compactMap(\.self).joined(separator: " ")) }
        if let bitrate, bitrate > 0 {
            items.append(String(localized: "\((Double(bitrate) / 1000).formatted(.number.precision(.fractionLength(1)))) Mbps",
                                comment: "A stream's bitrate, e.g. \"12.4 Mbps\""))
        }
        return items
    }
}

// MARK: - From the provider's measurements

nonisolated extension StreamDetails {
    init(_ info: XtreamVODTechnicalInfo) {
        runtime = MediaRuntime(seconds: info.durationSecs)
        resolution = Resolution(width: info.video?.width, height: info.video?.height)
        // PQ (smpte2084) or HLG (arib-std-b67) transfer is HDR.
        isHDR = ["smpte2084", "arib-std-b67"].contains(info.video?.colorTransfer?.lowercased() ?? "")
        frameRate = info.video?.frameRate.flatMap(Self.frameRate)
        videoCodec = info.video?.codecName.map(Self.codecLabel)
        audioCodec = info.audio?.codecName.map(Self.codecLabel)
        audioLayout = info.audio?.channels.flatMap { $0 > 0 ? AudioLayout(channels: $0) : nil }
        bitrate = info.bitrate
    }

    /// ffprobe's rational ("24000/1001") or a plain number ("25").
    private static func frameRate(_ value: String) -> Double? {
        let parts = value.split(separator: "/").compactMap { Double($0) }
        let rate = parts.count == 2 ? (parts[1] > 0 ? parts[0] / parts[1] : 0) : (parts.first ?? 0)
        return rate > 0 && rate < 240 ? rate : nil
    }

    private static func codecLabel(_ name: String) -> String {
        switch name.lowercased() {
        case "hevc", "h265": "HEVC"
        case "h264", "avc": "H.264"
        case "av1": "AV1"
        case "eac3": "Dolby Digital+"
        case "ac3": "Dolby Digital"
        case "truehd": "TrueHD"
        case "dts": "DTS"
        case "aac": "AAC"
        default: name.uppercased()
        }
    }
}

// MARK: - From a stream's name

nonisolated extension StreamDetails {
    /// What a provider's stream name claims: "Dune (2021) 4K HDR HEVC Atmos".
    init(name: String) {
        let words = Set(name.uppercased().split { !$0.isLetter && !$0.isNumber && $0 != "+" }.map(String.init))
        if !words.isDisjoint(with: ["4K", "2160P", "UHD"]) {
            resolution = .uhd
        } else if !words.isDisjoint(with: ["1080P", "FHD"]) {
            resolution = .fullHD
        } else if words.contains("720P") {
            resolution = .hd720
        }
        isHDR = !words.isDisjoint(with: ["HDR", "HDR10", "HDR10+"])
        if !words.isDisjoint(with: ["DV", "DOVI"]) || name.localizedCaseInsensitiveContains("Dolby Vision") { tags.append("Dolby Vision") }
        if !words.isDisjoint(with: ["HEVC", "H265", "X265"]) { videoCodec = "HEVC" }
        if words.contains("ATMOS") { tags.append("Atmos") }
        if words.contains("MULTI") { tags.append("MULTI") }
    }
}

// MARK: - Loading

/// The Source list's details, by copy. Name tags show at once; an Xtream
/// movie's measured details replace them when its `get_vod_info` returns.
/// Kept for the session, so reopening the list fetches nothing.
@Observable
final class StreamDetailsLoader {
    private(set) var details: [String: StreamDetails] = [:]
    private static var measured: [String: StreamDetails] = [:]
    @ObservationIgnored private let client: XtreamClient

    init(client: XtreamClient = XtreamClient()) {
        self.client = client
    }

    /// Already-fetched provider detail, never a title-level TMDB estimate.
    static func measuredRuntime(for id: String) -> MediaRuntime? {
        measured[id]?.runtime
    }

    func load(_ sources: [TitleSource], in context: ModelContext) async {
        for source in sources {
            details[source.id] = Self.nameDetails(source).merging(Self.measured[source.id] ?? StreamDetails())
        }
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        for source in sources where Self.measured[source.id] == nil {
            guard case let .movie(movie) = source.copy,
                  let playlist = PlaylistOwner.playlist(forContentID: movie.id, in: playlists),
                  playlist.sourceType == .xtream,
                  let info = try? await client.getVODInfo(playlist: playlist, vodId: movie.streamId).info
            else { continue }
            guard !Task.isCancelled else { return }
            let measured = StreamDetails(info)
            Self.measured[source.id] = measured
            details[source.id] = Self.nameDetails(source).merging(measured)
        }
    }

    private static func nameDetails(_ source: TitleSource) -> StreamDetails {
        switch source.copy {
        case let .movie(movie): StreamDetails(name: movie.name)
        case let .series(series): StreamDetails(name: series.name)
        }
    }
}
