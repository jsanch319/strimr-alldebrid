import Foundation

/// Tolerates Simkl's numeric and string representations of external IDs.
nonisolated struct SimklCatalogIDs: Codable, Hashable, Sendable {
    let simkl: String?
    let tmdb: String?
    let imdb: String?
    let tvdb: String?
    enum CodingKeys: String, CodingKey { case simkl, tmdb, imdb, tvdb }
    init(tmdb: String, imdb: String? = nil, tvdb: String? = nil) {
        simkl = nil; self.tmdb = tmdb; self.imdb = imdb; self.tvdb = tvdb
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            (try? values.decode(String.self, forKey: key)) ?? (try? values.decode(Int.self, forKey: key))
                .map(String.init)
        }
        simkl = text(.simkl); tmdb = text(.tmdb); imdb = text(.imdb); tvdb = text(.tvdb)
    }
}

nonisolated struct SimklListEntry: Codable, Hashable, Identifiable, Sendable {
    struct Media: Codable, Hashable, Sendable {
        let title: String?
        let year: Int?
        let ids: SimklCatalogIDs
    }

    struct Season: Codable, Hashable, Sendable {
        struct Episode: Codable, Hashable, Sendable { let number: Int; let watched_at: String? }
        let number: Int
        let episodes: [Episode]?
    }

    var status: String?
    let movie: Media?
    let show: Media?
    let last_watched_at: String?
    let next_to_watch: String?
    let seasons: [Season]?
    let watched_episodes_count: Int?
    let total_episodes_count: Int?
    static func planned(_ title: TMDBTitle) -> SimklListEntry {
        let media = Media(
            title: title.displayTitle,
            year: Int(title.date.prefix(4)),
            ids: SimklCatalogIDs(tmdb: String(title.id), imdb: title.matchingIDs.imdb, tvdb: title.matchingIDs.tvdb),
        )
        return SimklListEntry(
            status: "plantowatch",
            movie: title.kind == .movie ? media : nil,
            show: title.kind == .tv ? media : nil,
            last_watched_at: nil,
            next_to_watch: nil,
            seasons: nil,
            watched_episodes_count: nil,
            total_episodes_count: nil,
        )
    }

    /// Only entries with a TMDb ID enter TMDb discovery. Never guess an anime mapping.
    var media: Media? {
        movie ?? show
    }

    var kind: TMDBTitle.Kind {
        movie == nil ? .tv : .movie
    }

    var id: String {
        "\(kind.rawValue):\(media?.ids.simkl ?? media?.ids.tmdb ?? media?.ids.imdb ?? "unknown")"
    }

    var catalogID: String? {
        media?.ids.tmdb.map { "\(kind.rawValue):\($0)" }
    }

    var isPlanned: Bool {
        status == "plantowatch"
    }

    func watched(season: Int, episode: Int) -> Bool {
        seasons?.first { $0.number == season }?.episodes?.contains { $0.number == episode } == true
    }

    var nextEpisode: (season: Int, episode: Int)? {
        guard kind == .tv, status == "watching", let next_to_watch,
              let match = next_to_watch.range(of: #"^S\d+E\d+$"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let values = next_to_watch[match].uppercased().dropFirst().split(separator: "E").compactMap { Int($0) }
        guard values.count == 2 else { return nil }
        return (values[0], values[1])
    }
}

nonisolated struct SimklLibraryResponse: Codable, Sendable {
    let movies: [SimklListEntry]?
    let shows: [SimklListEntry]?
    let anime: [SimklListEntry]?
    var entries: [SimklListEntry] {
        (movies ?? []) + (shows ?? []) + (anime ?? [])
    }
}

nonisolated struct SimklActivities: Codable, Equatable, Sendable {
    struct Domain: Codable, Equatable, Sendable { let all: String?; let removed_from_list: String? }
    let all: String?
    let movies: Domain?
    let tv_shows: Domain?
    /// Anime without verified season mappings is deliberately outside this TMDb-based playback flow.
    var removals: [String?] {
        [movies?.removed_from_list, tv_shows?.removed_from_list]
    }
}

extension SimklClient {
    func activities() async throws -> SimklActivities {
        try await libraryRead("sync/activities").decode(SimklActivities.self)
    }

    func library(type: String, since: String? = nil, idsOnly: Bool = false) async throws -> [SimklListEntry] {
        var query = [URLQueryItem(name: "extended", value: idsOnly ? "ids_only" : "full")]
        if !idsOnly {
            query += [
                URLQueryItem(name: "include_all_episodes", value: "yes"),
                URLQueryItem(name: "episode_watched_at", value: "yes"),
            ]
        }
        if let since {
            query.append(URLQueryItem(name: "date_from", value: since))
        }
        return try await libraryRead("sync/all-items/\(type)", query: query).decode(SimklLibraryResponse.self).entries
    }

    func setPlanned(_ title: TMDBTitle, planned: Bool) async throws {
        var media: [String: Any] = ["ids": ["tmdb": String(title.id)], "title": title.displayTitle]
        if let year = Int(title.date.prefix(4)) {
            media["year"] = year
        }
        if planned {
            media["to"] = "plantowatch"
        }
        let body: [String: Any] = [title.kind == .movie ? "movies" : "shows": [media]]
        try await libraryWrite(planned ? "sync/add-to-list" : "sync/history/remove", body: body)
    }
}
