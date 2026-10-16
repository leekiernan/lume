import Foundation
@testable import Lume
import Testing

/// What the Source list says about a copy's stream.
struct StreamDetailsTests {
    @Test func `a stream name's tags become details`() {
        let details = StreamDetails(name: "Dune (2021) |4K| HDR10+ HEVC Dolby Vision Atmos MULTI")
        #expect(details.resolution == .uhd)
        #expect(details.isHDR)
        #expect(details.videoCodec == "HEVC")
        #expect(details.tags == ["Dolby Vision", "Atmos", "MULTI"])
        #expect(StreamDetails(name: "Dune (2021)") == StreamDetails())
    }

    @Test func `the provider's measurements become typed details`() throws {
        let json = Data("""
        {"info": {"bitrate": "12400",
                  "video": {"codec_name": "hevc", "width": 3840, "height": 1608,
                            "avg_frame_rate": "24000/1001", "color_transfer": "smpte2084"},
                  "audio": {"codec_name": "eac3", "channels": "6"}}}
        """.utf8)
        let info = try #require(try JSONDecoder().decode(XtreamVODInfoResponse.self, from: json).info)
        let details = StreamDetails(info)
        // A cropped 2.39:1 4K frame is still 4K.
        #expect(details.resolution == .uhd)
        #expect(details.isHDR)
        #expect(details.videoCodec == "HEVC")
        #expect(abs((details.frameRate ?? 0) - 23.976) < 0.001)
        #expect(details.audioCodec == "Dolby Digital+")
        #expect(details.audioLayout?.label == "5.1")
        #expect(details.bitrate == 12400)
    }

    @Test func `an absent stream arrives as an empty array and is skipped`() throws {
        let json = Data(#"{"info": {"video": [], "audio": [], "bitrate": 0}}"#.utf8)
        let info = try #require(try JSONDecoder().decode(XtreamVODInfoResponse.self, from: json).info)
        let details = StreamDetails(info)
        #expect(details.resolution == nil && details.audioLayout == nil && details.frameRate == nil)
    }

    @Test func `measurements win over what the name claims`() {
        var measured = StreamDetails()
        measured.resolution = .fullHD
        let merged = StreamDetails(name: "Film 4K Atmos").merging(measured)
        #expect(merged.resolution == .fullHD)
        #expect(merged.tags == ["Atmos"])
    }
}
