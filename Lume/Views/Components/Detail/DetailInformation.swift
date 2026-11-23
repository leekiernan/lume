//
//  DetailInformation.swift
//  Lume
//
//  The Information rows of a movie or series page, once for every platform.
//  iOS and tvOS each built their own list and had drifted: one said "Title"
//  and the other "Playlist Title", one called a show's creator its director,
//  and only tvOS listed the age rating — which every page's header already
//  shows.
//

import Foundation

enum DetailInformation {
    struct Row: Identifiable, Equatable {
        /// A localization key.
        let label: String
        let value: String

        var id: String {
            label
        }
    }

    static func rows(for movie: Movie) -> [Row] {
        rows(
            playlistTitle: movie.name, creditLabel: "Director", credit: movie.director, genre: movie.genre,
            cast: movie.orderedCast.isEmpty ? movie.actors : nil
        )
    }

    static func rows(for series: Series) -> [Row] {
        rows(
            playlistTitle: series.name, creditLabel: "Creator", credit: series.director, genre: series.genre,
            cast: series.orderedCast.isEmpty ? series.cast : nil
        )
    }

    /// The provider's name for the title (the page's heading is TMDB's), who
    /// made it, its genre, and the provider's cast when TMDB's isn't shown.
    private static func rows(playlistTitle: String, creditLabel: String, credit: String?, genre: String?, cast: String?) -> [Row] {
        var rows = [Row(label: "Playlist Title", value: playlistTitle)]
        for (label, value) in [(creditLabel, credit), ("Genre", genre), ("Cast", cast)] {
            if let value, !value.isEmpty { rows.append(Row(label: label, value: value)) }
        }
        return rows
    }
}
