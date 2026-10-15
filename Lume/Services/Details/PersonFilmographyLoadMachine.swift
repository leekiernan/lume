/// Credits and pages share one result-set identity. A context change revokes
/// page ownership before the credits lookup can suspend.
struct PersonFilmographyLoadMachine {
    struct Request: Equatable {
        let key: String
        private let token = RequestToken()
    }

    private enum Credits: Equatable {
        case idle
        case loading(Request)
        case ready(String)
    }

    private var credits: Credits = .idle
    private(set) var pagination = PaginationMachine()

    var isLoadingCredits: Bool {
        if case .ready = credits { return false }
        return true
    }

    mutating func beginCredits(for key: String) -> Request? {
        guard credits != .ready(key) else { return nil }
        let request = Request(key: key)
        credits = .loading(request)
        pagination.prepare(for: key)
        pagination.seed(nextOffset: 0, canLoadMore: false)
        return request
    }

    mutating func finishCredits(_ request: Request, hasEntries: Bool) -> Bool {
        guard credits == .loading(request) else { return false }
        credits = .ready(request.key)
        pagination.seed(nextOffset: 0, canLoadMore: hasEntries)
        return true
    }

    mutating func abandonCredits(_ request: Request) {
        if credits == .loading(request) { credits = .idle }
    }

    mutating func beginPage() -> PaginationMachine.Request? {
        guard case .ready = credits else { return nil }
        return pagination.beginLoading()
    }

    mutating func finishPage(_ request: PaginationMachine.Request, scanned: Int, hasMore: Bool) -> Bool {
        pagination.finish(request, scanned: scanned, hasMore: hasMore)
    }

    mutating func abandonPage(_ request: PaginationMachine.Request) {
        pagination.abandon(request)
    }

    mutating func cancelPage() {
        pagination.cancelLoading()
    }
}
