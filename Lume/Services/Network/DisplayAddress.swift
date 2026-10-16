import Foundation

/// Display is not request construction. Provider paths, queries and fragments
/// can all carry credentials; showing only the origin avoids guessing which
/// parameter names a particular provider regards as secret.
nonisolated enum DisplayAddress {
    static func origin(of raw: String) -> String {
        guard let url = URL(string: raw), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "—" }
        if url.isFileURL { return url.lastPathComponent }
        guard ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host?.isEmpty == false else { return "—" }
        parts.user = nil
        parts.password = nil
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? "—"
    }
}
