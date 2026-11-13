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
            session?.selectAudioTrack(id: index)
        }

        func selectTextTrack(id: String?) {
            let index = id.flatMap(Int.init)
            isExternalSubtitleSelected = index != nil && index == externalSubtitleTrackID
            session?.selectSubtitleTrack(id: index)
            if index == nil { subtitleCues.clear() }
        }

        /// Publishes the tracks and video description, assigning only what
        /// changed so an unchanged republish doesn't re-render the overlay.
        func publishMedia() {
            guard let session else { return }
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
                let published = PlayerVideoInfo(width: info.width, height: info.height, fps: info.frameRate ?? 0, codec: info.codec)
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
