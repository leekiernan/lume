import Foundation
@testable import Lume
import Testing

@MainActor
struct WidgetVisibilityTests {
    @Test func `a failed category read cannot authorize unrestricted export`() {
        let visibility = WidgetSnapshotExporter.visibility(isChildProfile: true) { throw CocoaError(.fileReadNoPermission) }
        #expect(visibility == nil)
    }

    @Test func `hidden categories apply to adults as well as children`() throws {
        let hidden = Lume.Category(apiId: "hidden", name: "Hidden", parentId: 0, type: .vod)
        hidden.isHidden = true
        let restricted = Lume.Category(apiId: "restricted", name: "Restricted", parentId: 0, type: .vod)
        restricted.isRestricted = true
        let adult = try #require(WidgetSnapshotExporter.visibility(isChildProfile: false) { [hidden, restricted] })
        let child = try #require(WidgetSnapshotExporter.visibility(isChildProfile: true) { [hidden, restricted] })
        #expect(adult.hides(categoryID: hidden.id))
        #expect(!adult.hides(categoryID: restricted.id))
        #expect(child.hides(categoryID: hidden.id) && child.hides(categoryID: restricted.id))
    }
}
