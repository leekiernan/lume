//
//  ForcedSubtitleName.swift
//  Lume
//
//  Recognises a foreign-parts-only ("forced") subtitle from its name, for the
//  places that have nothing better: KSPlayer reports no forced disposition at
//  all, a container's flag is often missing on IPTV muxes, and OpenSubtitles
//  uploaders don't always tick the box.
//
//  Matched on whole words, so `ENG_Forced`, `Avatar.en.forced.srt`,
//  `English (FORCED)` and `Movie.fpo.srt` count while `enforced` doesn't. A
//  bare "foreign" is deliberately not enough: releases named `Full+Foreign`
//  are complete subtitles that also cover the foreign dialogue.
//

import Foundation

nonisolated enum ForcedSubtitleName {
    /// Whether any of `names` marks a foreign-parts-only subtitle.
    static func matches(_ names: String?...) -> Bool {
        names.contains { $0.map(matches) ?? false }
    }

    static func matches(_ name: String) -> Bool {
        let words = name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if words.contains(where: markers.contains) { return true }
        return words.indices.dropLast(2).contains { index in
            Array(words[index ... index + 2]) == ["foreign", "parts", "only"]
        }
    }

    private static let markers: Set<String> = ["forced", "fpo"]
}
