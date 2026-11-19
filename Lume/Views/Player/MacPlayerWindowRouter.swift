//
//  MacPlayerWindowRouter.swift
//  Lume
//
//  Keeps macOS to ONE player, and owns the window it plays in.
//
//  `WindowGroup(id: "player", for: PlayableMedia.self)` keys a window on the
//  value it was opened with, so once the viewer steps to the next episode or
//  the next channel from inside the player, the open window no longer matches
//  the item the library shows as playing. Opening that item again would spawn
//  a second window — a second engine, a second audio session and a second Now
//  Playing publisher contending for the shared `MPRemoteCommandCenter`. So a
//  play request while a player is up raises that player and hands the stream
//  it actually wants to it through `pendingMedia`.
//
//  The player is either a window of its own or, when the viewer chose that in
//  Settings, an overlay on the library window it was started from. Either way
//  the router holds the `NSWindow`, so close, full screen and the window
//  buttons act on the player's window and never on whichever is frontmost.
//

import SwiftData
import SwiftUI

#if os(macOS)
    import AppKit

    @Observable
    final class MacPlayerWindowRouter {
        static let shared = MacPlayerWindowRouter()

        /// The value the player was created with. `nil` while there is no
        /// player, which is the only case that may open one.
        private var launchMedia: PlayableMedia?

        /// What the player is playing right now, so a request for the stream
        /// already on screen only raises the window.
        private var activeMediaID: String?

        /// A stream an outside call site asked the open player to switch to.
        /// The player consumes it and clears it.
        var pendingMedia: PlayableMedia?

        /// The stream a player in a library window was started with, and the
        /// window showing it. Both `nil` while the player has its own window.
        private(set) var inlineMedia: PlayableMedia?
        private(set) var inlineHostID: UUID?

        /// Whether the player's window is in full screen, or on its way there.
        /// The top bar reads it: there are no window buttons to clear then.
        private(set) var isFullScreen = false

        /// The window the player is in: its own, or the library window hosting
        /// it. `NSApp.keyWindow` is the library window whenever the player is
        /// not frontmost, which is exactly when acting on it would close,
        /// retitle or resize the wrong one.
        @ObservationIgnored private weak var window: NSWindow?
        @ObservationIgnored private weak var sourceSelection: TitleSourceSelection?

        /// The library windows a player can be shown in.
        @ObservationIgnored private var hosts: [UUID: WeakWindow] = [:]
        /// Whether the host window was in full screen before the player went
        /// up in it. A full screen entered for the video ends with the video;
        /// one the library was already in stays.
        @ObservationIgnored private var hostWasFullScreen = false
        /// Whether the host window's toolbar was taken down for the player.
        @ObservationIgnored private var hidHostToolbar = false
        /// Closes the player's own window before it has been adopted.
        @ObservationIgnored private var dismissOwnWindow: (() -> Void)?
        @ObservationIgnored private var fullScreenObservers: [NSObjectProtocol] = []
        @ObservationIgnored private var closeAfterFullScreenExit: NSObjectProtocol?

        private struct WeakWindow {
            weak var window: NSWindow?
        }

        private init() {}

        // MARK: Playing

        /// Whether the player is shown in a library window rather than its own.
        var isInline: Bool {
            inlineMedia != nil
        }

        /// Room the player's top bar leaves for the window buttons, which sit
        /// over its leading corner in a window and are gone in full screen.
        var windowButtonsInset: CGFloat {
            isFullScreen ? 0 : 56
        }

        /// Play `media`, creating a player only if there is none.
        func play(_ media: PlayableMedia, using openWindow: OpenWindowAction, sourceSelection: TitleSourceSelection? = nil) {
            if self.sourceSelection !== sourceSelection { self.sourceSelection?.showPicked() }
            self.sourceSelection = sourceSelection
            if let launchMedia {
                if media.id != activeMediaID { pendingMedia = media }
                raisePlayer(launchMedia: launchMedia, using: openWindow)
                return
            }
            // Claimed here rather than when the player appears, so a second
            // request in the same moment retargets this player instead of
            // opening another.
            launchMedia = media
            activeMediaID = media.id
            if MacPlayerPresentation.current == .currentWindow, let host = inlineHost() {
                hostWasFullScreen = host.window.styleMask.contains(.fullScreen)
                inlineHostID = host.id
                inlineMedia = media
            } else {
                openWindow(id: "player", value: media)
            }
        }

        private func raisePlayer(launchMedia: PlayableMedia, using openWindow: OpenWindowAction) {
            guard let window else {
                // Not adopted yet. Re-opening on the launch value focuses the
                // window that is on its way up rather than adding a second.
                if !isInline { openWindow(id: "player", value: launchMedia) }
                return
            }
            // `openWindow` leaves a minimised window in the Dock.
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }

        /// The library window to show the player in: the one the viewer is in,
        /// else any. `nil` when none can take it, and the player gets its own
        /// window. A window with a sheet up can't: the sheet would stay on top
        /// of the video.
        private func inlineHost() -> (id: UUID, window: NSWindow)? {
            hosts = hosts.filter { $0.value.window != nil }
            let candidates: [(id: UUID, window: NSWindow)] = hosts.compactMap { id, box in
                box.window.map { (id: id, window: $0) }
            }
            let usable = candidates.filter { $0.window.attachedSheet == nil && !$0.window.isMiniaturized }
            return usable.first { $0.window.isKeyWindow } ?? usable.first { $0.window.isMainWindow } ?? usable.first
        }

        func registerHost(_ id: UUID, window: NSWindow) {
            hosts[id] = WeakWindow(window: window)
        }

        func unregisterHost(_ id: UUID) {
            hosts[id] = nil
        }

        // MARK: Player lifecycle

        func playerDidOpen(with media: PlayableMedia, dismissOwnWindow: @escaping () -> Void) {
            // A window macOS restored at launch arrives here without `play`.
            if launchMedia == nil {
                launchMedia = media
                activeMediaID = media.id
            }
            self.dismissOwnWindow = dismissOwnWindow
        }

        func playerDidClose() {
            sourceSelection?.showPicked()
            sourceSelection = nil
            // The library window outlives the player it hosted.
            setWindowButtonsVisible(true)
            if hidHostToolbar {
                window?.toolbar?.isVisible = true
                hidHostToolbar = false
            }
            stopObservingFullScreen()
            launchMedia = nil
            activeMediaID = nil
            pendingMedia = nil
            inlineMedia = nil
            inlineHostID = nil
            dismissOwnWindow = nil
            window = nil
            isFullScreen = false
        }

        func noteActiveMedia(_ media: PlayableMedia, in context: ModelContext) {
            activeMediaID = media.id
            sourceSelection?.recordPlayback(media.contentRef, in: context)
            // Only ever the player's own window: a library window keeps its
            // title, and until a window has identified itself this is a no-op
            // rather than retitling whatever happened to be frontmost.
            if !isInline { window?.title = media.title }
        }

        func adopt(_ window: NSWindow, title: String) {
            guard self.window !== window else { return }
            self.window = window
            observeFullScreen(of: window)
            guard !isInline else {
                // The tab bar and the library's toolbar items would otherwise
                // sit on top of the video. Hidden on the window rather than
                // with `toolbarVisibility`, which takes the window buttons
                // down with the toolbar.
                if window.toolbar?.isVisible == true {
                    window.toolbar?.isVisible = false
                    hidHostToolbar = true
                }
                return
            }
            window.title = title
            window.collectionBehavior.insert(.fullScreenPrimary)
        }

        // MARK: Window actions

        /// Leave the player. Full screen is left first, and the window closed
        /// only once that transition has finished: closing a window in the
        /// middle of it strands an empty full-screen Space.
        func close() {
            if isInline {
                if let window, window.styleMask.contains(.fullScreen), !hostWasFullScreen {
                    window.toggleFullScreen(nil)
                }
                inlineMedia = nil
                inlineHostID = nil
                return
            }
            guard let window else {
                dismissOwnWindow?()
                return
            }
            guard window.styleMask.contains(.fullScreen) else {
                window.close()
                return
            }
            guard closeAfterFullScreenExit == nil else { return }
            closeAfterFullScreenExit = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let observer = self?.closeAfterFullScreenExit {
                        NotificationCenter.default.removeObserver(observer)
                        self?.closeAfterFullScreenExit = nil
                    }
                    window?.close()
                }
            }
            window.toggleFullScreen(nil)
        }

        /// Toggle full screen on the player's window. False when there is none.
        @discardableResult
        func toggleFullScreen() -> Bool {
            guard let window else { return false }
            window.toggleFullScreen(nil)
            return true
        }

        /// The close, minimise and zoom buttons come and go with the player's
        /// controls. Left up, they are the one thing that never leaves a video.
        func setWindowButtonsVisible(_ visible: Bool) {
            guard let window else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = !visible
            }
        }

        // MARK: Full screen tracking

        private func observeFullScreen(of window: NSWindow) {
            stopObservingFullScreen()
            isFullScreen = window.styleMask.contains(.fullScreen)
            // `will` for both, so the top bar moves with the transition
            // instead of jumping once it has landed.
            let changes: [(Notification.Name, Bool)] = [
                (NSWindow.willEnterFullScreenNotification, true),
                (NSWindow.didEnterFullScreenNotification, true),
                (NSWindow.willExitFullScreenNotification, false),
                (NSWindow.didExitFullScreenNotification, false)
            ]
            fullScreenObservers = changes.map { name, fullScreen in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.isFullScreen = fullScreen }
                }
            }
        }

        private func stopObservingFullScreen() {
            fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
            fullScreenObservers = []
            if let closeAfterFullScreenExit {
                NotificationCenter.default.removeObserver(closeAfterFullScreenExit)
                self.closeAfterFullScreenExit = nil
            }
        }
    }

    /// Reports the window a view is mounted in.
    ///
    /// The player used to find its window by asking for `NSApp.keyWindow` a beat
    /// after appearing. That is a guess: the viewer may have clicked back to the
    /// library in the meantime, and it resolved to whichever window was frontmost
    /// — which then had its title rewritten on every in-player swap. A view can
    /// only ever be in one window, so it asks its own, each time it joins one.
    struct MacWindowAccessor: NSViewRepresentable {
        let onResolve: (NSWindow) -> Void

        func makeNSView(context _: Context) -> NSView {
            let view = WindowReportingView()
            view.onResolve = onResolve
            return view
        }

        func updateNSView(_ view: NSView, context _: Context) {
            (view as? WindowReportingView)?.onResolve = onResolve
        }

        private final class WindowReportingView: NSView {
            var onResolve: ((NSWindow) -> Void)?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window else { return }
                // Out of the view update that put the view in the window.
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let window, self?.window === window else { return }
                    self?.onResolve?(window)
                }
            }
        }
    }

    extension View {
        /// Bind the player to the single macOS player: adopt its window on
        /// appear, release it on close, keep the window's title on the stream
        /// actually playing, and swap to a stream a library call site asked for.
        func macPlayerWindow(
            activeMedia: PlayableMedia,
            launchMedia: PlayableMedia,
            onRetarget: @escaping (PlayableMedia) -> Void
        ) -> some View {
            modifier(
                MacPlayerWindowModifier(
                    activeMedia: activeMedia, launchMedia: launchMedia, onRetarget: onRetarget
                )
            )
        }

        /// Lets this library window show the player, for viewers who chose to
        /// play in the current window. Applied inside the browse root's
        /// environment so the player inherits it, as a cover would.
        func macInlinePlayerHost() -> some View {
            modifier(MacInlinePlayerHost())
        }

        /// Moves a player's top bar clear of the window buttons.
        func macWindowButtonsInset() -> some View {
            padding(.leading, MacPlayerWindowRouter.shared.windowButtonsInset)
        }
    }

    private struct MacPlayerWindowModifier: ViewModifier {
        let activeMedia: PlayableMedia
        let launchMedia: PlayableMedia
        let onRetarget: (PlayableMedia) -> Void

        @State private var router = MacPlayerWindowRouter.shared
        @Environment(\.modelContext) private var modelContext
        @Environment(\.dismissWindow) private var dismissWindow

        func body(content: Content) -> some View {
            content
                .background {
                    MacPlayerKeyboardCommands()
                }
                .background(MacWindowAccessor { window in
                    // Adopt the player's window: its own, or the library window
                    // hosting it. Its own opens as a window, the way a Mac app
                    // should — going full screen is the viewer's call — and
                    // SwiftUI's frame autosave brings it back at the size and
                    // position it was last left at.
                    router.adopt(window, title: activeMedia.title)
                })
                .onAppear {
                    router.playerDidOpen(with: launchMedia) { dismissWindow(id: "player") }
                }
                .onDisappear { router.playerDidClose() }
                .onChange(of: activeMedia, initial: true) { _, media in router.noteActiveMedia(media, in: modelContext) }
                .onChange(of: router.pendingMedia, initial: true) { _, media in
                    guard let media else { return }
                    router.pendingMedia = nil
                    onRetarget(media)
                }
        }
    }

    private struct MacInlinePlayerHost: ViewModifier {
        @State private var hostID = UUID()
        @State private var router = MacPlayerWindowRouter.shared

        private var media: PlayableMedia? {
            router.inlineHostID == hostID ? router.inlineMedia : nil
        }

        func body(content: Content) -> some View {
            content
                .background(MacWindowAccessor { router.registerHost(hostID, window: $0) })
                .onDisappear { router.unregisterHost(hostID) }
                .overlay {
                    if let media {
                        FullScreenPlayerView(media: media)
                    }
                }
        }
    }

    /// Where a stream opens on macOS.
    nonisolated enum MacPlayerPresentation: String, CaseIterable, Identifiable {
        /// A player window of its own, beside the library.
        case newWindow
        /// Over the library window it was started from.
        case currentWindow

        static let `default` = MacPlayerPresentation.newWindow

        var id: String {
            rawValue
        }

        static func resolve(_ raw: String?) -> MacPlayerPresentation {
            raw.flatMap(MacPlayerPresentation.init(rawValue:)) ?? .default
        }

        static var current: MacPlayerPresentation {
            resolve(UserDefaults.standard.string(forKey: PlayerSettings.macPlayerPresentationKey))
        }
    }

    /// Always mounted, unlike each engine's auto-hiding controls. Native key
    /// equivalents work even when the video renderer owns keyboard focus.
    private struct MacPlayerKeyboardCommands: View {
        private func acceptsShortcut() -> Bool {
            guard let window = NSApp.keyWindow else { return false }
            return MacWindowShortcutPolicy.accepts(isEditingText: window.firstResponder is NSTextView,
                                                   hasPresentedSheet: window.attachedSheet != nil)
        }

        var body: some View {
            HStack {
                Button("Close player") {
                    if acceptsShortcut() { MacPlayerWindowRouter.shared.close() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Full Screen") {
                    if acceptsShortcut() { MacPlayerWindowRouter.shared.toggleFullScreen() }
                }
                .keyboardShortcut("f", modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    struct MacPlayerFullScreenButton: View {
        var body: some View {
            Button {
                MacPlayerWindowRouter.shared.toggleFullScreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glassEffectCompat(.regularInteractive, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Full Screen")
            .help("Full Screen")
        }
    }

#else

    extension View {
        /// No-op off macOS, where the player is presented in-place rather than
        /// in a window of its own.
        func macPlayerWindow(
            activeMedia _: PlayableMedia,
            launchMedia _: PlayableMedia,
            onRetarget _: @escaping (PlayableMedia) -> Void
        ) -> some View {
            self
        }

        /// No-op off macOS: there are no window buttons to clear.
        func macWindowButtonsInset() -> some View {
            self
        }
    }

#endif
