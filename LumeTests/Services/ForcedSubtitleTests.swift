import Foundation
@testable import Lume
import Testing

struct ForcedSubtitleTests {
    // MARK: - Names

    @Test(arguments: [
        "English (FORCED)",
        "Avatar.2009.EXTENDED.1080p.BluRay.H264.AAC-RARBG.en.forced",
        "Avatar.2009.Bluray.1080p.DTSMA.x264.dxva-FraMeSToR.ENG_Forced",
        "Avatar.2009.[ExtendedCut].BDRip.1080p.Eng-Forced",
        "Movie.2024.fpo.srt",
        "English Forced",
        "English Subtitles for Foreign Parts Only"
    ])
    func `a forced name is recognised`(name: String) {
        #expect(ForcedSubtitleName.matches(name))
    }

    /// `Full+Foreign` releases are complete subtitles that also cover the
    /// foreign dialogue, so a bare "foreign" must not count.
    @Test(arguments: [
        "Avatar.2009.Theatrical.Full+Foreign.UHD.BluRay.1080p",
        "English",
        "Enforced.Silence.2024.1080p",
        "Foreign.Correspondent.1940.BDRip",
        "English SDH"
    ])
    func `an ordinary name is not`(name: String) {
        #expect(!ForcedSubtitleName.matches(name))
    }

    @Test func `any of several names can mark it`() {
        #expect(ForcedSubtitleName.matches(nil, "Avatar.en.forced"))
        #expect(!ForcedSubtitleName.matches(nil, "Avatar.en"))
    }

    // MARK: - Search

    private func queryItems(_ query: OpenSubtitlesQuery) throws -> [String: String?] {
        let url = try #require(OpenSubtitlesClient.searchURL(for: query))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
    }

    @Test func `foreign parts only asks the api to filter`() throws {
        let items = try queryItems(OpenSubtitlesQuery(tmdbId: 19995, languages: ["en"], foreignPartsOnly: true))
        #expect(items["foreign_parts_only"] == "only")
    }

    /// Off leaves the API's default, which includes both kinds.
    @Test func `a normal search sends no forced filter`() throws {
        let items = try queryItems(OpenSubtitlesQuery(tmdbId: 19995, languages: ["en"]))
        #expect(items["foreign_parts_only"] == nil)
    }

    @Test func `the title-only retry keeps the forced filter`() {
        let query = OpenSubtitlesQuery(text: "Avatar", tmdbId: 19995, foreignPartsOnly: true)
        #expect(query.titleOnly.foreignPartsOnly)
    }

    // MARK: - Results

    private func decode(_ attributes: String) throws -> OnlineSubtitle {
        let json = #"{ "attributes": { "language": "en", "files": [{ "file_id": 1, "file_name": "Avatar" }], "#
            + attributes + " } }"
        let item = try JSONDecoder().decode(OpenSubtitlesSearchItem.self, from: Data(json.utf8))
        return try #require(item.subtitle)
    }

    @Test func `the api flag marks a record forced`() throws {
        #expect(try decode(#""foreign_parts_only": true, "release": "Avatar.2009""#).isForeignPartsOnly)
        #expect(try !decode(#""foreign_parts_only": false, "release": "Avatar.2009""#).isForeignPartsOnly)
    }

    @Test func `an unflagged record named forced still counts`() throws {
        #expect(try decode(#""release": "Avatar.2009.Eng-Forced""#).isForeignPartsOnly)
    }

    @Test func `a forced record carries a badge`() throws {
        let subtitle = try decode(#""foreign_parts_only": true"#)
        #expect(subtitle.badges.contains { $0.id == "forced" })
    }

    @Test @MainActor func `forced results rank after full ones`() {
        func subtitle(_ id: String, downloads: Int, forced: Bool) -> OnlineSubtitle {
            OnlineSubtitle(
                id: id, fileID: 1, languageCode: "en", releaseName: "", downloadCount: downloads,
                isHearingImpaired: false, isMachineTranslated: false, isFromTrusted: false, rating: 0,
                isForeignPartsOnly: forced
            )
        }
        let ranked = OpenSubtitlesService.ranked([
            subtitle("forced-popular", downloads: 900, forced: true),
            subtitle("full", downloads: 10, forced: false),
            subtitle("full-popular", downloads: 500, forced: false),
            subtitle("forced", downloads: 5, forced: true)
        ])
        #expect(ranked.map(\.id) == ["full-popular", "full", "forced-popular", "forced"])
    }
}
