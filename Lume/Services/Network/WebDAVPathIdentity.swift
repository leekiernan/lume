import Foundation

nonisolated enum WebDAVPathIdentity {
    /// Operational boundary only; do not change the persisted item identity.
    /// Resolve decoded dot segments before checking the share root, including
    /// escaped separators/dots returned by a non-conforming listing.
    static func contains(_ resource: URL, in collection: URL) -> Bool {
        guard let origin = HTTPOrigin(collection), origin == HTTPOrigin(resource) else { return false }
        let root = segments(collection)
        return segments(resource).starts(with: root)
    }

    private static func segments(_ url: URL) -> [String] {
        var result: [String] = []
        for segment in url.path(percentEncoded: false).split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": if !result.isEmpty { result.removeLast() }
            default: result.append(String(segment))
            }
        }
        return result
    }

    /// Preserve the parser/walker's existing identity: query-insensitive,
    /// percent-decoded, case-sensitive, and ignoring one trailing slash.
    static func key(_ absoluteString: String) -> String {
        let withoutQuery = absoluteString.split(separator: "?", maxSplits: 1).first.map(String.init) ?? absoluteString
        let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
        return decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
    }
}
