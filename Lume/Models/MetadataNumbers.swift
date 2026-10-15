import Foundation

/// A score retains its scale; presentation never has to parse a label back
/// into a number. Validate at every construction, including stored decoding.
nonisolated struct RatingScore: Codable, Hashable {
    enum Scale: Int, Codable { case five = 5, ten = 10, percentage = 100 }

    let value: Double
    let scale: Scale

    init?(_ value: Double?, scale: Scale) {
        guard let value, value.isFinite, (0 ... Double(scale.rawValue)).contains(value) else { return nil }
        self.value = value
        self.scale = scale
    }

    var percentage: Double {
        value / Double(scale.rawValue) * 100
    }

    var fiveBased: Double {
        value / Double(scale.rawValue) * 5
    }

    var tenBased: Double {
        value / Double(scale.rawValue) * 10
    }

    private enum CodingKeys: String, CodingKey { case value, scale }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let value = try values.decode(Double.self, forKey: .value)
        let scale = try values.decode(Scale.self, forKey: .scale)
        guard let score = Self(value, scale: scale) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: values, debugDescription: "Invalid rating score")
        }
        self = score
    }
}

/// A known positive runtime. Unit conversion cannot overflow even when a
/// syntactically valid provider/proxy payload contains an extreme integer.
nonisolated struct MediaRuntime: Hashable {
    let seconds: Int

    init?(seconds: Int?) {
        guard let seconds, seconds > 0 else { return nil }
        self.seconds = seconds
    }

    init?(minutes: Int?) {
        guard let minutes, minutes > 0 else { return nil }
        let converted = minutes.multipliedReportingOverflow(by: 60)
        guard !converted.overflow else { return nil }
        seconds = converted.partialValue
    }

    var minutes: Int {
        seconds / 60
    }
}
