/// Presentation only: the caller's pagination/import machine still owns work.
/// Existing rows remain usable while another page or a refresh is in flight.
enum CollectionGridPresentation: Equatable {
    case content
    case loading
    case empty
    /// Nothing to show because the first page failed.
    case failed

    static func resolve(hasItems: Bool, isLoading: Bool, hasFailed: Bool = false) -> Self {
        if hasItems { return .content }
        if isLoading { return .loading }
        return hasFailed ? .failed : .empty
    }
}
