//
//  AetherEngineCoordinator+PictureInPicture.swift
//  Lume
//
//  Picture in Picture and leaving the foreground. The controller is built
//  after the first load returns (the route decides which layer it wraps) and
//  refreshed after each later one; a window's own pause is the window's, not
//  an unrequested live pause.
//

#if !os(visionOS)

    import Foundation
    import LumeAetherBridge

    extension AetherEngineCoordinator {
        func togglePictureInPicture() {
            pictureInPicture?.toggle()
        }

        /// The app left the foreground without a PiP window to keep playing in.
        func pauseForBackground() {
            guard !isPipActive, isPlaying else { return }
            pause()
        }

        func setUpPictureInPicture() {
            guard !isEmbedded, let session = session as? LumeAetherSession else { return }
            if let pictureInPicture {
                pictureInPicture.refresh()
                return
            }
            let controller = AetherPictureInPictureController(session: session)
            controller.onActiveChange = { [weak self] active in
                self?.isPipActive = active
                self?.pictureInPictureDidChange(active: active)
            }
            controller.onStop = { [weak self] in
                self?.onPictureInPictureStop?()
            }
            controller.onSupportChange = { [weak self] supported in
                self?.isPipSupported = supported
            }
            isPipSupported = controller.isSupported
            pictureInPicture = controller
        }
    }

    extension AetherEngineCoordinator: NowPlayingControllable {}

    #if os(tvOS)
        /// The shared Apple TV overlay drives AetherEngine through the same
        /// surface as every other engine; every requirement already exists.
        extension AetherEngineCoordinator: TVPlaybackEngine {}
    #endif

#endif
