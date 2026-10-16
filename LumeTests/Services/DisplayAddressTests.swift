import Foundation
@testable import Lume
import Testing

struct DisplayAddressTests {
    @Test func `all credential locations are excluded from display`() {
        #expect(DisplayAddress.origin(of: "https://user:secret@example.test:8443/user/secret/get.php?password=secret&token=secret#secret") == "https://example.test:8443")
        #expect(DisplayAddress.origin(of: "not a URL containing a secret") == "—")
        #expect(DisplayAddress.origin(of: "file:///tmp/playlist.m3u") == "playlist.m3u")
    }
}
