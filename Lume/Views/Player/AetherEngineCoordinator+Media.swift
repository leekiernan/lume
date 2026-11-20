//
//  AetherEngineCoordinator+Media.swift
//  Lume
//
//  The stream's tracks and video description for the overlay menus, track
//  picks, and the sidecar subtitle from the OpenSubtitles search.
//

#if !os(visionOS)

    import Foundation
    import LumeAetherBridge
    import OSLog

    extension AetherEngineCoordinator {
        func selectAudioTrack(id: String) {
            guard let index = Int(id) else { return }
            manualAudioTrackID = index
            if let track = session?.audioTracks.first(where: { $0.id == index }) {
                trackCarryOver?.noteAudio(Self.carried(track))
            }
            session?.selectAudioTrack(id: index)
        }

        func selectTextTrack(id: String?) {
            let index = id.flatMap(Int.init)
            isExternalSubtitleSelected = index != nil && index == externalSubtitleTrackID
            hasPendingCarriedSubtitle = false
            if index == nil {
                trackCarryOver?.noteSubtitle(.off)
            } else if let track = session?.subtitleTracks.first(where: { $0.id == index }), !track.isExternal {
                trackCarryOver?.noteSubtitle(.track(Self.carried(track), isForced: Self.isForced(track)))
            }
            session?.selectSubtitleTrack(id: index)
            if index == nil { subtitleCues.clear() }
        }

        /// Publishes the tracks and video description, assigning only what
        /// changed so an unchanged republish doesn't re-render the overlay.
        func publishMedia() {
            guard let session else { return }
            applyCarriedSubtitle(on: session)
            preferAudioChannels(of: session)
            let audio = session.audioTracks.enumerated().map { position, track in
                PlayerTrackOption(
                    id: String(track.id),
                    label: Self.label(track, fallback: "Audio \(position + 1)"),
                    isSelected: session.activeAudioTrackID.map { $0 == track.id } ?? (position == 0)
                )
            }
            let text = session.subtitleTracks.enumerated().map { position, track in
                PlayerTrackOption(
                    id: String(track.id),
                    label: track.isExternal && track.id == externalSubtitleTrackID
                        ? externalSubtitle?.label ?? track.name
                        : Self.label(track, fallback: "Subtitle \(position + 1)"),
                    isSelected: session.activeSubtitleTrackID == track.id
                )
            }
            if audio != audioTrackOptions { audioTrackOptions = audio }
            if text != textTrackOptions { textTrackOptions = text }
            if let info = session.videoInfo {
                let published = PlayerVideoInfo(
                    width: info.width,
                    height: info.height,
                    fps: info.frameRate ?? 0,
                    codec: info.codec,
                    dynamicRange: PlayerDynamicRange(session.dynamicRange)
                )
                if published != videoInfo { videoInfo = published }
            }
        }

        /// A load forgets runtime tracks, so the sidecar file is listed again
        /// after each one.
        func restoreExternalSubtitle(on session: any AetherSessionDriving) {
            guard let externalSubtitle else { return }
            let id = session.addExternalSubtitle(fileURL: externalSubtitle.fileURL, name: externalSubtitle.label)
            externalSubtitleTrackID = id
            if isExternalSubtitleSelected { session.selectSubtitleTrack(id: id) }
        }

        /// The container's forced disposition, or a track named for it: IPTV
        /// muxes often drop the flag and keep "English Forced" as the title.
        private static func isForced(_ track: LumeAetherTrack) -> Bool {
            track.isForced || ForcedSubtitleName.matches(track.name)
        }

        /// Puts the subtitle pick carried from the last episode back on, once
        /// the engine lists the stream's own tracks.
        private func applyCarriedSubtitle(on session: any AetherSessionDriving) {
            guard hasPendingCarriedSubtitle, let carry = trackCarryOver?.carry else { return }
            let tracks = session.subtitleTracks.filter { !$0.isExternal }
            guard !tracks.isEmpty else { return }
            hasPendingCarriedSubtitle = false
            let candidates = tracks.map { TrackCarryOver.Candidate(track: Self.carried($0), isForced: Self.isForced($0)) }
            switch carry.resolveSubtitle(in: candidates) {
            case .keep: break
            case .off: session.selectSubtitleTrack(id: nil)
            case let .select(index): session.selectSubtitleTrack(id: tracks[index].id)
            }
        }

        /// The playing track's channel count for the audio session. The engine
        /// writes this itself on its renderer paths; its AVPlayer path leaves
        /// the session as it found it, so the app sets it there. A Multi-View
        /// tile leaves the session's width alone.
        private func preferAudioChannels(of session: any AetherSessionDriving) {
            guard !isEmbedded else { return }
            let tracks = session.audioTracks
            let playing = tracks.first { $0.id == session.activeAudioTrackID } ?? tracks.first
            PlayerAudioChannelPreference.apply(sourceChannels: playing?.channels)
        }

        private static func carried(_ track: LumeAetherTrack) -> TrackCarryOver.Track {
            TrackCarryOver.Track(languageTag: track.language, label: track.name.isEmpty ? nil : track.name)
        }

        private static func label(_ track: LumeAetherTrack, fallback: String) -> String {
            if !track.name.isEmpty { return track.name }
            if let language = track.language, !language.isEmpty {
                return TrackLanguageMatcher.displayName(for: language)
            }
            return fallback
        }
    }

    extension AetherEngineCoordinator: ExternalSubtitleLoading {
        func loadExternalSubtitle(_ subtitle: ExternalSubtitle) {
            externalSubtitle = subtitle
            isExternalSubtitleSelected = true
            subtitleCues.clear()
            guard let session else { return }
            restoreExternalSubtitle(on: session)
            publishMedia()
        }
    }

#endif
