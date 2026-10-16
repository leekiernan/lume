//
//  XtreamVODInfo.swift
//  Lume
//
//  `get_vod_info`'s technical block, as the wire sends it: providers fill it
//  from ffprobe, so a field can be a number or a string, and a missing stream
//  arrives as an empty array rather than null. Decoded leniently here and
//  converted once into `StreamDetails`.
//

import Foundation

nonisolated struct XtreamVODInfoResponse: Decodable {
    let info: XtreamVODTechnicalInfo?

    enum CodingKeys: String, CodingKey {
        case info
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        info = try? container.decodeIfPresent(XtreamVODTechnicalInfo.self, forKey: .info)
    }
}

nonisolated struct XtreamVODTechnicalInfo: Decodable {
    let video: XtreamVideoStream?
    let audio: XtreamAudioStream?
    /// Kilobits per second.
    let bitrate: Int?
    let durationSecs: Int?

    enum CodingKeys: String, CodingKey {
        case video, audio, bitrate
        case durationSecs = "duration_secs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An absent stream is `[]`, which doesn't decode as an object.
        video = try? container.decodeIfPresent(XtreamVideoStream.self, forKey: .video)
        audio = try? container.decodeIfPresent(XtreamAudioStream.self, forKey: .audio)
        bitrate = container.lenientInt(forKey: .bitrate)
        durationSecs = container.lenientInt(forKey: .durationSecs)
    }
}

nonisolated struct XtreamVideoStream: Decodable {
    let codecName: String?
    let width: Int?
    let height: Int?
    /// ffprobe's rational, e.g. "24000/1001".
    let frameRate: String?
    let colorTransfer: String?

    enum CodingKeys: String, CodingKey {
        case codecName = "codec_name"
        case width, height
        case frameRate = "r_frame_rate"
        case averageFrameRate = "avg_frame_rate"
        case colorTransfer = "color_transfer"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codecName = container.lenientString(forKey: .codecName)
        width = container.lenientInt(forKey: .width)
        height = container.lenientInt(forKey: .height)
        frameRate = container.lenientString(forKey: .averageFrameRate) ?? container.lenientString(forKey: .frameRate)
        colorTransfer = container.lenientString(forKey: .colorTransfer)
    }
}

nonisolated struct XtreamAudioStream: Decodable {
    let codecName: String?
    let channels: Int?

    enum CodingKeys: String, CodingKey {
        case codecName = "codec_name"
        case channels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codecName = container.lenientString(forKey: .codecName)
        channels = container.lenientInt(forKey: .channels)
    }
}
