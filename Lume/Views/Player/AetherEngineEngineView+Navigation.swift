//
//  AetherEngineEngineView+Navigation.swift
//  Lume
//
//  Stream changes from inside the AetherEngine host: the on-screen
//  previous/next pair (iOS, macOS), and the Siri Remote's channel surfing and
//  channel browser (tvOS). Every change goes back out through the host's
//  swapper, the only place allowed to change the stream.
//

#if !os(visionOS)

    import SwiftUI

    extension AetherEngineEngineView {
        #if os(tvOS)
            func switchLiveChannel(_ direction: MoveCommandDirection) {
                mediaSwapper.surf(
                    direction, from: media,
                    through: .init(restriction: restriction, context: modelContext, neighbours: itemNeighbours),
                    select: { onSelectMedia?($0) },
                    showControls: { chrome.show(mayHide: { canAutoHideControls }) }
                )
            }

            var channelBrowser: some View {
                TVPlayerChannelBrowser(
                    media: media, isPresented: $isChannelBrowserOpen, chrome: chrome,
                    mayHide: { canAutoHideControls }, onSelect: { onSelectMedia?($0) },
                    onClose: { closeChannelBrowser() }
                )
            }

            func openChannelBrowser() {
                chrome.openBrowser(isLive: media.isLive, isPresented: $isChannelBrowserOpen)
            }

            func closeChannelBrowser() {
                chrome.closeBrowser(isPresented: $isChannelBrowserOpen, mayHide: { canAutoHideControls })
                // Hand focus back to the tap-catcher so the remote keeps working.
                Task { @MainActor in catcherFocused = true }
            }
        #else
            func stepItem(_ step: PlayerMediaSwapper.Step) {
                mediaSwapper.step(
                    step, in: itemNeighbours,
                    onCompleteCurrentItem: { onCompleteCurrentItem?() },
                    select: { onSelectMedia?($0) }
                )
            }
        #endif
    }

#endif
