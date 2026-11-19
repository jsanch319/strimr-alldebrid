import Foundation

/// Tolerates Simkl's numeric and string representations of external IDs.
nonisolated struct SimklCatalogIDs: Codable, Hashable, Sendable {
    let simkl: String?
    let tmdb: String?
    let imdb: String?
    let tvdb: String?
    enum CodingKeys: String, CodingKey { case simkl, tmdb, imdb, tvdb }
    init(tmdb: String?, imdb: String? = nil, tvdb: String? = nil, simkl: String? = nil) {
        self.simkl = simkl; self.tmdb = tmdb; self.imdb = imdb; self.tvdb = tvdb
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
    static func planned(_ title: TMDBTitle, ids: SimklCatalogIDs? = nil) -> SimklListEntry {
        let media = Media(
            title: title.displayTitle,
            year: Int(title.date.prefix(4)),
            ids: ids ?? SimklCatalogIDs(
                tmdb: String(title.id),
                imdb: title.matchingIDs.imdb,
                tvdb: title.matchingIDs.tvdb,
            ),
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
        guard let raw = media?.ids.tmdb, let id = Int(raw), id > 0 else { return nil }
        return "\(kind.rawValue):\(id)"
    }

    var isPlanned: Bool {
        status == "plantowatch"
    }

    /// Attach the caller's TMDb identity only after the server row has been matched.
    /// Some Simkl responses contain only the canonical ID, which cannot drive TMDb cards alone.
    func resolvingCatalogIdentity(_ title: TMDBTitle, knownIDs: SimklCatalogIDs) -> Self {
        let resolved = Media(
            title: media?.title ?? title.displayTitle,
            year: media?.year ?? Int(title.date.prefix(4)),
            ids: SimklCatalogIDs(
                tmdb: String(title.id),
                imdb: media?.ids.imdb ?? knownIDs.imdb,
                tvdb: media?.ids.tvdb ?? knownIDs.tvdb,
                simkl: media?.ids.simkl ?? knownIDs.simkl,
            ),
        )
        return Self(
            status: status, movie: kind == .movie ? resolved : nil, show: kind == .tv ? resolved : nil,
            last_watched_at: last_watched_at, next_to_watch: next_to_watch, seasons: seasons,
            watched_episodes_count: watched_episodes_count, total_episodes_count: total_episodes_count,
        )
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
    struct Domain: Codable, Equatable,
        Sendable { let all: String?; let removed_from_list: String?; let playback: String? }
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
        try await libraryDecode(SimklActivities.self, path: "sync/activities")
    }

    func library(
        type: String,
        since: String? = nil,
        idsOnly: Bool = false,
        status: String? = nil,
    ) async throws -> [SimklListEntry] {
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
        let path = "sync/all-items/\(type)" + (status.map { "/\($0)" } ?? "")
        return try await libraryDecode(SimklLibraryResponse.self, path: path, query: query).entries
    }

    func markCatalogWatched(_ title: TMDBTitle, episode: TMDBEpisode?, at date: Date) async throws {
        guard let item = title.trackerItem(episode: episode),
              let body = TrackerRequestBody.history(
                  [TrackerHistoryEntry(item: item, watchedAt: date)],
                  media: SimklAPI.media,
              )
        else { throw TrackerAPIError.unavailable }
        try await libraryWrite("sync/history", body: body)
    }

    @discardableResult
    func setPlanned(
        _ title: TMDBTitle,
        planned: Bool,
        knownIDs: SimklCatalogIDs? = nil,
    ) async throws -> SimklListEntry? {
        guard title.id > 0 else { throw TrackerAPIError.invalidResponse }
        let ids = SimklCatalogIDs(
            tmdb: String(title.id),
            imdb: title.matchingIDs.imdb ?? knownIDs?.imdb,
            tvdb: title.matchingIDs.tvdb ?? knownIDs?.tvdb,
            simkl: knownIDs?.simkl,
        )
        var sentIDs: [String: String] = ["tmdb": String(title.id)]
        sentIDs["imdb"] = ids.imdb; sentIDs["tvdb"] = ids.tvdb; sentIDs["simkl"] = ids.simkl
        var media: [String: Any] = ["ids": sentIDs, "title": title.displayTitle]
        if let year = Int(title.date.prefix(4)) {
            media["year"] = year
        }
        if planned {
            media["to"] = "plantowatch"
        }
        let key = title.kind == .movie ? "movies" : "shows"
        let result = try await libraryWrite(planned ? "sync/add-to-list" : "sync/history/remove", body: [key: [media]])
        var confirmationIDs = ids
        if planned, let rows = (result["added"] as? [String: Any])?[key] as? [[String: Any]] {
            for row in rows {
                if let type = row["type"] as? String, type != (title.kind == .movie ? "movie" : "show") {
                    throw SimklWatchlistError.notConfirmed
                }
                guard let rawIDs = row["ids"] else { continue }
                let decoded = try JSONDecoder().decode(
                    SimklCatalogIDs.self,
                    from: JSONSerialization.data(withJSONObject: rawIDs),
                )
                guard !SimklWatchlistIdentity.conflicts(decoded, requested: ids) else {
                    throw SimklWatchlistError.notConfirmed
                }
                // Simkl may return only its canonical ID instead of echoing external IDs.
                // Unknown identity requires read-back; conflicting identity is rejected.
                let status = row["to"] as? String ?? row["status"] as? String
                guard let status else { continue }
                guard status == "plantowatch" else { throw SimklWatchlistError.notConfirmed }
                if !SimklWatchlistIdentity.matches(decoded, requested: ids) {
                    // This POST submits exactly one item. A single canonical acknowledgement
                    // in its namespace can identify that request for a subsequent status read.
                    // It is not enough by itself to show success. Never adopt conflicting IDs.
                    if rows.count == 1, let canonical = decoded.simkl, !canonical.isEmpty {
                        confirmationIDs = SimklCatalogIDs(
                            tmdb: ids.tmdb, imdb: ids.imdb, tvdb: ids.tvdb, simkl: canonical,
                        )
                    }
                    continue
                }
                return .planned(title, ids: SimklCatalogIDs(
                    tmdb: String(title.id),
                    imdb: decoded.imdb ?? ids.imdb,
                    tvdb: decoded.tvdb ?? ids.tvdb,
                    simkl: decoded.simkl ?? ids.simkl,
                ))
            }
        }
        if !planned, let deleted = result["deleted"] as? [String: Any],
           let countData = try? JSONSerialization.data(withJSONObject: deleted),
           let counts = try? JSONDecoder().decode([String: Int].self, from: countData),
           counts[key] == 1
        {
            return nil
        }
        // Legacy/count-only envelopes do not establish title identity. Read back once;
        // never retry a POST after an uncertain server-side outcome.
        guard result[planned ? "added" : "deleted"] is [String: Any] else { throw TrackerAPIError.invalidResponse }
        let rows: [SimklListEntry]
        do { rows = try await library(type: key, status: "plantowatch") }
        catch {
            SimklSyncFailure.record(error, stage: "watchlist_confirmation")
            // Keep actionable authorization and quota failures intact instead of
            // hiding them behind a generic confirmation error.
            switch error as? TrackerAPIError {
            case .unauthorized, .sessionExpired, .rateLimited, .unexpected(status: 403), .throttled:
                throw error
            default: break
            }
            throw SimklWatchlistError.confirmationUnavailable
        }
        let matching = rows
            .first { $0.kind == title.kind && $0.isPlanned && $0.media.map { SimklWatchlistIdentity.matches(
                $0.ids,
                requested: confirmationIDs,
            ) } == true }
        if planned {
            guard let matching else { throw SimklWatchlistError.notConfirmed }
            return matching.resolvingCatalogIdentity(title, knownIDs: confirmationIDs)
        }
        guard matching == nil else { throw SimklWatchlistError.notConfirmed }
        return nil
    }
}

nonisolated enum SimklWatchlistError: LocalizedError {
    case notConfirmed, confirmationUnavailable, busy
    var errorDescription: String? {
        switch self {
        case .notConfirmed: "Simkl did not confirm the requested watchlist state. Refresh My List before retrying."
        case .confirmationUnavailable: "The request may have reached Simkl, but its watchlist state could not be checked. Refresh My List when Simkl is available."
        case .busy: "This watchlist item is already being updated."
        }
    }

    static func message(_ error: Error) -> String {
        if let error = error as? Self {
            return error.errorDescription ?? "Simkl could not confirm this update."
        }
        if let network = error as? URLError {
            return network.code == .notConnectedToInternet ?
                "Connect to the internet and retry. Simkl has not confirmed this watchlist update." :
                "Couldn't reach Simkl to confirm this update. Your saved watchlist is retained. Retry when connected."
        }
        switch error as? TrackerAPIError {
        case .unauthorized, .sessionExpired, .unavailable: return "Connect or reconnect Simkl in Settings to update My List."
        case .rateLimited: return "Simkl's request limit was reached. Retry after the limit resets; reconnecting does not reset it."
        case .notFound: return "Simkl could not match this title. Your saved watchlist was retained."
        case .unexpected(status: 403), .throttled: return "Simkl denied this update. Check app access and write permission in Simkl settings."
        case .invalidResponse: return "Simkl returned an unreadable save response. Your saved watchlist is retained. Please refresh My List before retrying."
        default: return "Simkl could not confirm this update. Your saved watchlist was retained. Please refresh before retrying."
        }
    }
}

nonisolated enum SimklWatchlistIdentity {
    private static func pairs(_ returned: SimklCatalogIDs, _ requested: SimklCatalogIDs) -> [(String?, String?)] {
        [
            (returned.tmdb, requested.tmdb),
            (returned.simkl, requested.simkl),
            (returned.imdb, requested.imdb),
            (returned.tvdb, requested.tvdb),
        ]
    }

    static func conflicts(_ returned: SimklCatalogIDs, requested: SimklCatalogIDs) -> Bool {
        pairs(returned, requested).contains { $0.0 != nil && $0.1 != nil && $0.0 != $0.1 }
    }

    static func matches(_ returned: SimklCatalogIDs, requested: SimklCatalogIDs) -> Bool {
        guard !conflicts(returned, requested: requested) else { return false }
        return pairs(returned, requested).contains { $0.0 != nil && $0.0 == $0.1 }
    }
}
