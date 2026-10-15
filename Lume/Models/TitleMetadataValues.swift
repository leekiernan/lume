import Foundation

/// Mapping at the model boundary keeps storage/query columns scalar while
/// giving callers validated values with explicit units and scales.
nonisolated extension Movie {
    var ratingScore: RatingScore? {
        get { RatingScore(rating, scale: .ten) }
        set { rating = newValue?.tenBased ?? 0 }
    }

    var starRating: RatingScore? {
        if let score = RatingScore(rating5Based, scale: .five), score.value > 0 { return score }
        guard let score = ratingScore, score.value > 0 else { return nil }
        return RatingScore(score.fiveBased, scale: .five)
    }

    var runtime: MediaRuntime? {
        get { MediaRuntime(seconds: durationSecs) }
        set { durationSecs = newValue?.seconds }
    }
}

nonisolated extension Series {
    var ratingScore: RatingScore? {
        get { RatingScore(rating.flatMap(Double.init), scale: .ten) }
        set { rating = newValue.map { String($0.tenBased) } }
    }

    var starRating: RatingScore? {
        if let score = RatingScore(rating5Based.flatMap(Double.init), scale: .five), score.value > 0 { return score }
        guard let score = ratingScore, score.value > 0 else { return nil }
        return RatingScore(score.fiveBased, scale: .five)
    }
}

nonisolated extension Episode {
    var ratingScore: RatingScore? {
        get { RatingScore(rating, scale: .ten) }
        set { rating = newValue?.tenBased }
    }

    var runtime: MediaRuntime? {
        get { MediaRuntime(seconds: durationSecs) }
        set { durationSecs = newValue?.seconds }
    }
}
