import Foundation

/// A provider must explicitly identify the requested catalog item; filenames are checked again before playback.
nonisolated struct AuthorizedSourceCandidate: Codable, Sendable {
    let tmdbID: Int
    let kind: String
    let year: Int
    let season: Int?
    let episode: Int?
    let filename: String
    let link: String
    let authorized: Bool

    @MainActor func matches(_ title: TMDBTitle, episode selected: TMDBEpisode?) -> Bool {
        authorized && tmdbID == title.id && kind == (title.kind == .movie ? "movie" : "tv")
            && year == Int(title.date.prefix(4)) && season == selected?.season_number
            && episode == selected?.episode_number
            && AllDebridTitleMatcher.matches(title: title, episode: selected, filename: filename)
    }

    @MainActor static func matchesFile(_ filename: String, title: TMDBTitle, episode: TMDBEpisode?) -> Bool {
        guard AllDebridTitleMatcher.matches(title: title, episode: episode, filename: filename) else { return false }
        guard title.kind == .movie else { return true }
        let hasID = filename.range(of: #"(?i)tmdb[\s:=_{\[-]+\d+|\btt\d{5,}\b"#, options: .regularExpression) != nil
        guard !hasID else { return true }
        guard let year = Int(title.date.prefix(4)) else { return false }
        return filename.range(of: "(?<![0-9])\(year)(?![0-9])", options: .regularExpression) != nil
    }

    static func validLink(_ text: String) -> Bool {
        guard let components = URLComponents(string: text), components.user == nil,
              components.password == nil else { return false }
        if components.scheme?.lowercased() == "magnet" {
            return components.queryItems?.contains {
                $0.name == "xt" && ($0.value?.range(
                    of: #"^urn:btih:(?:[a-fA-F0-9]{40}|[A-Z2-7a-z]{32})$"#,
                    options: .regularExpression,
                ) != nil)
            } == true
        }
        return ["https", "http"].contains(components.scheme?.lowercased() ?? "") && components.host != nil
    }
}

nonisolated protocol AuthorizedSourceProvider: Sendable {
    func search(title: TMDBTitle, episode: TMDBEpisode?) async throws -> [AuthorizedSourceCandidate]
}

/// User-configured JSON endpoints only. No scraper, default indexer, credentials, or protected stream extraction.
nonisolated struct HTTPSAuthorizedSourceProvider: AuthorizedSourceProvider {
    let endpoint: URL
    var session: URLSession = .shared

    static func endpoint(_ text: String) -> URL? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "https", c.host != nil, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil else { return nil }
        return c.url
    }

    func search(title: TMDBTitle, episode: TMDBEpisode?) async throws -> [AuthorizedSourceCandidate] {
        guard Self.endpoint(endpoint.absoluteString) != nil else { throw URLError(.badURL) }
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "tmdb_id", value: String(title.id)),
            URLQueryItem(name: "kind", value: title.kind == .movie ? "movie" : "tv"),
            URLQueryItem(name: "title", value: title.displayTitle),
            URLQueryItem(name: "year", value: String(title.date.prefix(4))),
        ]
        if let episode {
            c.queryItems! += [
                URLQueryItem(name: "season", value: String(episode.season_number)),
                URLQueryItem(name: "episode", value: String(episode.episode_number)),
            ]
        }
        var request = URLRequest(url: c.url!)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, raw) = try await session.data(for: request)
        guard let response = raw as? HTTPURLResponse,
              response.url?.scheme == "https" else { throw URLError(.badServerResponse) }
        guard (200 ... 299).contains(response.statusCode)
        else { throw AllDebridAPIClient.APIError.httpStatus(response.statusCode) }
        guard data.count <= 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
        return try Array(JSONDecoder().decode([AuthorizedSourceCandidate].self, from: data).prefix(50))
    }
}

nonisolated enum AuthorizedSourceSettings {
    static let key = "catalog.authorizedSourceEndpoints"
    static func providers(_ text: String) -> [HTTPSAuthorizedSourceProvider] {
        Array(Set(text.components(separatedBy: .newlines).compactMap(HTTPSAuthorizedSourceProvider.endpoint)))
            .sorted { $0.absoluteString < $1.absoluteString }.prefix(5).map { .init(endpoint: $0) }
    }
}
