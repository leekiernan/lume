//
//  OpenSubtitlesSearchItem.swift
//  Lume
//
//  The `/subtitles` record as the API sends it, and its reduction to the
//  `OnlineSubtitle` the picker shows. Split out of OpenSubtitlesClient.swift
//  to keep that file within the project's size limit.
//

import Foundation

/// One downloadable file of a subtitle record. Multi-CD releases list several.
nonisolated struct OpenSubtitlesFileDTO: Decodable {
    let fileID: Int?
    let fileName: String?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileName = "file_name"
    }
}

/// The per-record fields the picker shows. The rest of each record (uploader,
/// related links, legacy ids) is ignored.
nonisolated struct OpenSubtitlesAttributesDTO: Decodable {
    let subtitleID: String?
    let language: String?
    let downloadCount: Int?
    let hearingImpaired: Bool?
    let foreignPartsOnly: Bool?
    let machineTranslated: Bool?
    let aiTranslated: Bool?
    let fromTrusted: Bool?
    let ratings: Double?
    let release: String?
    let files: [OpenSubtitlesFileDTO]?

    enum CodingKeys: String, CodingKey {
        case subtitleID = "subtitle_id"
        case language
        case downloadCount = "download_count"
        case hearingImpaired = "hearing_impaired"
        case foreignPartsOnly = "foreign_parts_only"
        case machineTranslated = "machine_translated"
        case aiTranslated = "ai_translated"
        case fromTrusted = "from_trusted"
        case ratings
        case release
        case files
    }
}

/// One `/subtitles` record.
nonisolated struct OpenSubtitlesSearchItem: Decodable {
    let attributes: OpenSubtitlesAttributesDTO

    /// `nil` for a record with no downloadable file or no language — neither can
    /// be offered to the viewer, and both appear occasionally in the feed.
    var subtitle: OnlineSubtitle? {
        guard let file = attributes.files?.first, let fileID = file.fileID,
              let language = attributes.language, !language.isEmpty
        else { return nil }
        return OnlineSubtitle(
            id: attributes.subtitleID ?? String(fileID),
            fileID: fileID,
            languageCode: language,
            releaseName: attributes.release ?? file.fileName ?? "",
            downloadCount: attributes.downloadCount ?? 0,
            isHearingImpaired: attributes.hearingImpaired ?? false,
            isMachineTranslated: (attributes.machineTranslated ?? false) || (attributes.aiTranslated ?? false),
            isFromTrusted: attributes.fromTrusted ?? false,
            rating: attributes.ratings ?? 0,
            // The uploader's flag, backed up by the names: some forced uploads
            // arrive unflagged but called `….en.forced` or `(FORCED)`.
            isForeignPartsOnly: (attributes.foreignPartsOnly ?? false)
                || ForcedSubtitleName.matches(attributes.release, file.fileName)
        )
    }
}
