import Foundation
@testable import Lume
import Testing

@MainActor
struct BrowseSidebarStateTests {
    @Test func `cancel returns to the exact opener rather than the last panel row`() async {
        let state = BrowseSidebarState()
        let opener = UUID()
        var returned: [UUID] = []
        state.rememberContentFocus(id: opener) { valid in
            if valid() { returned.append(opener) }
        }
        state.isPresented = true
        state.rememberedRowID = "category-175"
        state.releaseContentFocus(id: opener)
        state.rememberContentFocus(id: UUID()) { _ in Issue.record("Panel landing replaced its opener") }
        await state.dismissToContent()?.value
        #expect(returned == [opener])
        #expect(state.rememberedRowID == "category-175")
    }

    @Test func `opening from another control replaces the previous bookmark`() async {
        let state = BrowseSidebarState()
        var returned: [String] = []
        for name in ["rail title", "first card", "browse button", "guide", "sports highlight"] {
            state.rememberContentFocus(id: UUID()) { valid in
                if valid() { returned.append(name) }
            }
            state.isPresented = true
            await state.dismissToContent()?.value
        }
        #expect(returned == ["rail title", "first card", "browse button", "guide", "sports highlight"])
    }

    @Test func `category activation never restores the underlying opener`() {
        let state = BrowseSidebarState()
        state.rememberContentFocus(id: UUID()) { _ in Issue.record("Navigation restored old content") }
        state.isPresented = true
        state.activate(rowID: "category") {}
        #expect(state.dismissToContent() == nil)
    }

    @Test func `a control removed while browsing is never restored`() {
        let state = BrowseSidebarState()
        let id = UUID()
        state.rememberContentFocus(id: id) { _ in Issue.record("Restored a removed control") }
        state.isPresented = true
        state.removeContentFocus(id: id)
        #expect(state.dismissToContent() == nil)
    }

    @Test func `reopening cancels a pending return before it asserts focus`() async {
        let state = BrowseSidebarState()
        state.rememberContentFocus(id: UUID()) { valid in
            #expect(!valid())
        }
        state.isPresented = true
        let pending = state.dismissToContent()
        state.isPresented = true
        await pending?.value
        #expect(state.isPresented)
    }

    @Test func `removing a control cancels an already scheduled return`() async {
        let state = BrowseSidebarState()
        let id = UUID()
        state.rememberContentFocus(id: id) { valid in
            #expect(!valid())
        }
        state.isPresented = true
        let pending = state.dismissToContent()
        state.removeContentFocus(id: id)
        await pending?.value
    }

    @Test func `a double dismissal returns focus only once`() async {
        let state = BrowseSidebarState()
        var returns = 0
        state.rememberContentFocus(id: UUID()) { valid in
            if valid() { returns += 1 }
        }
        state.isPresented = true
        let pending = state.dismissToContent()
        #expect(state.dismissToContent() == nil)
        await pending?.value
        #expect(returns == 1)
    }

    @Test func `leaving or changing the content scope invalidates its opener`() async {
        let state = BrowseSidebarState()
        state.rememberContentFocus(id: UUID()) { valid in #expect(!valid()) }
        state.isPresented = true
        let pending = state.dismissToContent()
        state.invalidateContentFocus()
        await pending?.value
        state.isPresented = true
        #expect(state.dismissToContent() == nil)
    }

    @Test func `reopening during a settling return cannot steal focus from the panel`() async {
        let state = BrowseSidebarState()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (settle, didSettle) = AsyncStream<Void>.makeStream()
        state.rememberContentFocus(id: UUID()) { valid in
            #expect(valid())
            didStart.yield()
            for await _ in settle {
                break
            }
            #expect(!valid())
        }
        state.isPresented = true
        let pending = state.dismissToContent()
        for await _ in started {
            break
        }
        state.isPresented = true
        didSettle.yield()
        await pending?.value
        didStart.finish()
        didSettle.finish()
        #expect(state.isPresented)
    }

    @Test func `focus that left the page before opening is not a return target`() {
        let state = BrowseSidebarState()
        let id = UUID()
        state.rememberContentFocus(id: id) { _ in Issue.record("Restored stale content focus") }
        state.releaseContentFocus(id: id)
        state.isPresented = true
        #expect(state.dismissToContent() == nil)
    }

    @Test func `activation remembers and dismisses before navigating exactly once`() {
        let state = BrowseSidebarState()
        state.isPresented = true
        var visits = 0
        state.activate(rowID: "category") {
            visits += 1
            #expect(state.rememberedRowID == "category")
            #expect(!state.isPresented)
        }
        #expect(visits == 1)
    }

    @Test func `closing without navigation preserves the remembered off-screen row`() {
        let state = BrowseSidebarState()
        state.rememberedRowID = "category-175"
        state.isPresented = true
        state.isPresented = false
        state.isPresented = true
        let ids = (0 ..< 200).map { "category-\($0)" }
        #expect(BrowseSidebarFocusPolicy.landingID(lastFocusedID: state.rememberedRowID, availableIDs: ids) == "category-175")
    }

    @Test func `all areas use the same activation owner without sharing each others position`() {
        let areas = ["movies", "series", "live", "sports"]
        let states = areas.map { _ in BrowseSidebarState() }
        for (index, state) in states.enumerated() {
            state.isPresented = true
            state.activate(rowID: areas[index]) {}
        }
        #expect(states.map(\.rememberedRowID) == areas.map(Optional.some))
        #expect(states.allSatisfy { !$0.isPresented })
        states[0].rememberedRowID = "another-movie-category"
        #expect(states[1].rememberedRowID == "series")
    }

    @Test func `a secondary action uses the same dismissal path as category navigation`() {
        let state = BrowseSidebarState()
        state.isPresented = true
        var showingManagement = false
        state.activate(rowID: "manage") {
            #expect(!state.isPresented)
            showingManagement = true
        }
        #expect(showingManagement)
        #expect(state.rememberedRowID == "manage")
    }
}
