/// Exactly one Player drill-in is open. Menu derives its parent from the same
/// route the view renders, rather than prioritising independent flags.
nonisolated enum PlayerSettingsRoute: Equatable {
    enum LanguagePane: Equatable { case list, add }

    case overview
    case engine(PlayerEngineKind)
    case languages(LanguagePane)
    case subtitleStyle

    @discardableResult
    mutating func goBack() -> Bool {
        switch self {
        case .overview: return false
        case .languages(.add): self = .languages(.list)
        case .engine, .languages(.list), .subtitleStyle: self = .overview
        }
        return true
    }
}
