//
//  KSPlayerEngineView+Options.swift
//  Lume
//
//  Builds the `KSOptions` for a playback session from the user's saved KSPlayer
//  settings (see `KSPlayerOptions`). Split out of `KSPlayerEngineView` to keep
//  that view file focused on the SwiftUI body.
//

#if os(tvOS) || os(visionOS)
    import AVKit
#endif
import CoreMedia
import Foundation
import KSPlayer
import os
import SwiftUI

/// `KSOptions` that resolves the viewer's preferred audio language while the
/// stream is being opened.
///
/// `wantedAudio(tracks:)` is the only sanctioned pre-selection hook: KSPlayer
/// consults it inside `MEPlayerItem`'s open, before any decoder exists, so no
/// track ever starts and gets swapped. `player.select(track:)` stays reserved
/// for manual picks, and re-preparing a running layer to apply a language is a
/// documented use-after-free.
///
/// Only audio. KSPlayer declares no wanted-subtitle counterpart and reports no
/// forced disposition, so subtitle pre-selection and forced-subtitle handling
/// are not available on this engine. The hook also lives on the FFmpeg engine
/// alone — `KSAVPlayer` never reads it.
final nonisolated class LumeKSOptions: KSOptions {
    private let preferredAudioLanguages: [String]

    /// A manual pick wins for the rest of the stream. `rebuildStream(on:)` and
    /// `reconnect()` re-open with this very options instance, which would
    /// otherwise re-assert the preference over the viewer's choice on every
    /// live zap, stall recovery and reconnect. Scoped to one stream: the
    /// coordinator builds a fresh options object whenever the URL changes, so
    /// the flag cannot leak into the next channel or episode.
    ///
    /// Written from the main actor, read on KSPlayer's open thread.
    private let hasManualAudioSelection = OSAllocatedUnfairLock(initialState: false)

    /// Whether this session may switch the TV's display mode when the tvOS
    /// "Match Content" settings are on. KSPlayer sets the frame rate and dynamic
    /// range once the first frame decodes, and clears them when the layer
    /// deinits, so on an embedded tile every channel change clears the mode and
    /// sets it again: two HDMI re-syncs, a black screen each time. Only full
    /// screen matches the display, the way AVKit only does it for full-screen
    /// playback. Fixed for the session: the fork has no embedded session that
    /// full screen later adopts.
    private let matchesDisplayCriteria: Bool

    /// Where hand picks are recorded for the next episode; nil outside the
    /// full-screen player. Main actor only, like the picks themselves.
    weak var trackCarryOver: TrackCarryOverSession?

    init(preferredAudioLanguages: [String], matchesDisplayCriteria: Bool) {
        self.preferredAudioLanguages = preferredAudioLanguages
        self.matchesDisplayCriteria = matchesDisplayCriteria
        super.init()
    }

    /// Process-wide, like the display it guards: an episode swap hands the
    /// player a fresh options object, and what was applied must carry over.
    @MainActor private static var displayGate = DisplayCriteriaGate()
    @MainActor private static var displaySettle: Task<Void, Never>?
    /// The outgoing player's reset of the display mode, held back so the next
    /// title can claim the mode first — see `playerLayerDeinit`.
    @MainActor private static var displayReset: Task<Void, Never>?
    /// Long enough for the next episode's first frame (joins run 1–4 s, plus
    /// the settle), short enough that leaving the player soon restores the
    /// interface's mode.
    private static let displayResetDelay: Duration = .seconds(5)

    /// Settles KSPlayer's display-mode requests before any reaches the TV,
    /// and drops one that matches the mode already set — see
    /// `DisplayCriteriaGate`.
    @MainActor
    override func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription?) {
        guard matchesDisplayCriteria else { return }
        // KSPlayer only switches once the dynamic range is known.
        guard let range = isDovi ? .dolbyVision : formatDescription?.dynamicRange else { return }
        Self.displayGate.request(.init(refreshRate: refreshRate, dynamicRange: range.rawValue))
        // A title is playing again: the outgoing one's reset is moot.
        Self.displayReset?.cancel()
        Self.displaySettle?.cancel()
        Self.displaySettle = Task {
            try? await Task.sleep(for: DisplayCriteriaGate.settleDelay)
            guard !Task.isCancelled else { return }
            guard Self.displayGate.settle() else {
                Logger.player.info("display mode unchanged at \(refreshRate, format: .fixed(precision: 3), privacy: .public) fps, range \(range.rawValue, privacy: .public)")
                return
            }
            Logger.player.info("display mode → \(refreshRate, format: .fixed(precision: 3), privacy: .public) fps, range \(range.rawValue, privacy: .public)")
            super.updateVideo(refreshRate: refreshRate, isDovi: isDovi, formatDescription: formatDescription)
        }
    }

    /// An embedded session never set the display mode, so it must not reset
    /// it either — that would knock full screen, or the next tile, back to the
    /// interface's mode.
    ///
    /// Not reset at once: KSPlayer gets a fresh player per episode, and
    /// clearing the mode as the old one goes would make every episode change
    /// two HDMI switches (to the interface's mode and straight back), the
    /// back-to-back switching that has hung tvOS 27.2's display. The reset
    /// waits, and the next title's first request cancels it; an episode in
    /// the same format then never touches the display.
    override func playerLayerDeinit() {
        guard matchesDisplayCriteria else { return }
        guard Thread.isMainThread else {
            Task { @MainActor in Self.scheduleDisplayReset() }
            return
        }
        MainActor.assumeIsolated { Self.scheduleDisplayReset() }
    }

    @MainActor
    private static func scheduleDisplayReset() {
        displayReset?.cancel()
        displayReset = Task {
            try? await Task.sleep(for: displayResetDelay)
            guard !Task.isCancelled else { return }
            displaySettle?.cancel()
            displayGate.reset()
            Logger.player.info("display mode → interface")
            #if os(tvOS) || os(visionOS)
                let window = UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.windows.first }
                    .first
                window?.avDisplayManager.preferredDisplayCriteria = nil
            #endif
        }
    }

    /// Call from every manual audio-track pick, before `select(track:)`.
    func noteManualAudioSelection() {
        hasManualAudioSelection.withLock { $0 = true }
    }

    /// `nil` leaves KSPlayer's own choice (`av_find_best_stream`) untouched —
    /// never index 0, which would change playback for streams whose languages
    /// the viewer never asked about.
    override func wantedAudio(tracks: [MediaPlayerTrack]) -> Int? {
        guard !preferredAudioLanguages.isEmpty else { return nil }
        guard !hasManualAudioSelection.withLock({ $0 }) else { return nil }
        return TrackLanguageMatcher.bestMatchIndex(
            in: tracks.map { TrackLanguageMatcher.Track(languageTag: $0.languageCode, label: $0.name) },
            preferring: preferredAudioLanguages
        )
    }
}

extension KSVideoPlayer.Coordinator {
    /// The one sanctioned way to pick an audio track by hand: the
    /// preferred-audio-language pass has to stand down for the rest of the
    /// stream, which every overlay would otherwise have to remember. Callers
    /// publish their own change afterwards.
    func selectAudioTrack(_ track: MediaPlayerTrack) {
        let options = playerLayer?.options as? LumeKSOptions
        options?.noteManualAudioSelection()
        options?.trackCarryOver?.noteAudio(.init(languageTag: track.languageCode, label: track.name))
        playerLayer?.player.select(track: track)
    }

    /// The one sanctioned way to pick a subtitle by hand (`nil` is Off), so
    /// the pick carries into the next episode. Embedded tracks only: a
    /// side-loaded file belongs to the stream it was found for.
    func selectSubtitle(_ info: (any SubtitleInfo)?) {
        subtitleModel.selectedSubtitleInfo = info
        let carry = (playerLayer?.options as? LumeKSOptions)?.trackCarryOver
        guard let info else {
            carry?.noteSubtitle(.off)
            return
        }
        guard let track = info as? MediaPlayerTrack else { return }
        carry?.noteSubtitle(.track(
            .init(languageTag: track.languageCode, label: info.name),
            isForced: KSSubtitleCarry.isForced(info)
        ))
    }

    /// Re-applies a subtitle pick carried from the last episode, once
    /// KSPlayer has listed this stream's embedded tracks (and made its own
    /// auto-selection, which this replaces).
    func applyCarriedSubtitle(_ carry: TrackCarryOver) {
        let infos = subtitleModel.subtitleInfos
        let candidates = infos.map { info in
            TrackCarryOver.Candidate(
                track: .init(languageTag: (info as? MediaPlayerTrack)?.languageCode, label: info.name),
                isForced: KSSubtitleCarry.isForced(info)
            )
        }
        switch carry.resolveSubtitle(in: candidates) {
        case .keep: break
        case .off: subtitleModel.selectedSubtitleInfo = nil
        case let .select(index): subtitleModel.selectedSubtitleInfo = infos[index]
        }
    }
}

/// KSPlayer reports no forced disposition for a subtitle track, only its
/// title; a forced track is named for it ("English Forced", "Forced", "FPO").
enum KSSubtitleCarry {
    static func isForced(_ info: any SubtitleInfo) -> Bool {
        ForcedSubtitleName.matches(info.name)
    }
}

/// Turns the user's saved KSPlayer settings into a `KSOptions` for one stream.
/// Shared by the full-screen engine view and the Multi-View tiles, which need
/// the same decoder/buffer tuning but must not claim Picture in Picture.
enum KSPlayerOptionsFactory {
    /// Process-wide KSPlayer configuration, applied exactly once on first
    /// access (static `let` init is lazy and thread-safe). These are global
    /// settings, so assigning them on every `make` call was a needless side
    /// effect from a view body.
    static let configureGlobalOptions: Void = {
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.isAutoPlay = true
        KSOptions.isPipPopViewController = false

        #if DEBUG
            KSOptions.logLevel = .warning
        #else
            KSOptions.logLevel = .error
        #endif
    }()

    /// - Parameter isEmbedded: `true` for a Multi-View tile. Four tiles each
    ///   allowed to start PiP from inline would fight over the one PiP window,
    ///   and a tile switching the TV's display mode blacks out the whole screen
    ///   on every channel change.
    /// - Parameter trackCarryOver: the full-screen player's carried picks;
    ///   the stream starts with the carried audio language first.
    static func make(
        for media: PlayableMedia,
        isEmbedded: Bool = false,
        trackCarryOver: TrackCarryOverSession? = nil
    ) -> KSOptions {
        _ = configureGlobalOptions

        let settings = KSPlayerOptions.load()
        // System-proxy use and the primary engine are process-wide statics with
        // no per-instance counterpart, so they're applied on the type each time.
        // The layer reads `firstPlayerType` when it's created (in the view body),
        // so setting it here takes effect for this playback.
        KSOptions.useSystemHTTPProxy = settings.systemProxy
        KSOptions.firstPlayerType = settings.primaryEngine == .ffmpeg ? KSMEPlayer.self : KSAVPlayer.self

        trackCarryOver?.begin(media)
        let preferred = PlayerLanguageOptions.load().preferredAudioLanguages
        let options = LumeKSOptions(
            preferredAudioLanguages: trackCarryOver?.carry.audioLanguages(over: preferred) ?? preferred,
            matchesDisplayCriteria: !isEmbedded
        )
        options.trackCarryOver = trackCarryOver
        // Now Playing metadata + remote commands are owned by
        // `NowPlayingService` for all engines; KSPlayer's built-in
        // registration would double-handle every command.
        options.registerRemoteControll = false
        options.hardwareDecode = settings.hardwareDecode
        options.asynchronousDecompression = settings.asyncDecompression
        options.isSecondOpen = settings.secondOpen
        options.isAccurateSeek = settings.accurateSeek
        options.isLoopPlay = settings.loopPlay
        options.autoDeInterlace = settings.autoDeinterlace
        options.autoRotate = settings.autoRotate
        options.videoAdaptable = settings.adaptive
        options.nobuffer = settings.noBuffer
        options.codecLowDelay = settings.codecLowDelay
        options.canStartPictureInPictureAutomaticallyFromInline = !isEmbedded && settings.autoPip
        options.autoSelectEmbedSubtitle = settings.autoSelectSubtitle
        // Catch-up gets a capped read-ahead — see `PlayerSettings.KSPlayer.catchupMaxBuffer`.
        let buffers = KSPlayerBufferDurations.resolve(
            liveBuffer: settings.liveBuffer,
            vodBuffer: settings.vodBuffer,
            maxBuffer: settings.maxBuffer,
            isLive: media.isLive,
            isCatchup: media.catchup != nil
        )
        options.maxBufferDuration = buffers.maximum
        options.preferredForwardBufferDuration = buffers.preferredForward
        // No `appendHeader`: FFmpeg would send its `headers` option to every
        // URL it opens. Credentials ride on `playerURL` (`PlaybackCredentials`).
        PlaybackCredentials.input(for: .ksPlayer, url: media.url, headers: media.httpHeaders).apply(to: options)
        if !media.isLive, media.startTime > 1 {
            options.startPlayTime = media.startTime
        }
        #if os(macOS)
            options.automaticWindowResize = false
        #endif
        return options
    }
}

extension KSPlayerEngineView {
    func makeOptions() -> KSOptions {
        let options = KSPlayerOptionsFactory.make(for: media, trackCarryOver: trackCarryOver)
        let resource = playbackResource ?? resourceRequest
        PlaybackCredentials.input(for: .ksPlayer, url: resource.url, headers: resource.headers).apply(to: options)
        return options
    }
}

nonisolated extension PlaybackCredentials.Input {
    /// KSPlayer's half of the input; the URL itself goes to `KSVideoPlayer`.
    func apply(to options: KSOptions) {
        options.avOptions["AVURLAssetHTTPHeaderFieldsKey"] = avFoundationHeaders
        options.formatContextOptions["auth_type"] = sendsBasicFirst ? "basic" : nil
    }
}
