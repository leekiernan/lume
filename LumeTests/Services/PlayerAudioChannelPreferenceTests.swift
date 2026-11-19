@testable import Lume
import Testing

/// Upstream 4ac01a2d: the session asks for the playing track's width, never
/// the route's maximum.
struct PlayerAudioChannelPreferenceTests {
    @Test func `a stereo track on a surround route asks for stereo`() {
        #expect(PlayerAudioChannelPreference.channels(forSource: 2, routeMaximum: 8) == 2)
    }

    @Test func `a surround track asks for its own width, capped by the route`() {
        #expect(PlayerAudioChannelPreference.channels(forSource: 6, routeMaximum: 8) == 6)
        #expect(PlayerAudioChannelPreference.channels(forSource: 8, routeMaximum: 6) == 6)
    }

    @Test func `mono and unknown tracks ask for stereo`() {
        #expect(PlayerAudioChannelPreference.channels(forSource: 1, routeMaximum: 6) == 2)
        #expect(PlayerAudioChannelPreference.channels(forSource: nil, routeMaximum: 6) == 2)
        #expect(PlayerAudioChannelPreference.channels(forSource: 0, routeMaximum: 6) == 2)
    }

    @Test func `a mono route is never asked for more than it has`() {
        #expect(PlayerAudioChannelPreference.channels(forSource: 6, routeMaximum: 1) == 1)
    }
}
