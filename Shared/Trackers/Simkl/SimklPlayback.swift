import Foundation

/// Shared "newest pending change wins" policy for server journals and Simkl checkpoints.
nonisolated enum PlaybackProgressConflict {
    static func prefersLocal(localDate: Date, isPending: Bool, remoteDate: Date?) -> Bool {
        isPending && (remoteDate.map { localDate > $0 } ?? true)
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func position(percentage: Double, duration: Double?) -> Double? {
        guard percentage.isFinite, (0 ... 100).contains(percentage),
              let duration, duration.isFinite, duration > 0 else { return nil }
        return min(duration, duration * percentage / 100)
    }
}

nonisolated struct SimklPausedPlayback: Decodable, Sendable {
    struct Media: Decodable, Sendable {
        let title: String?
        let year: Int?
        let ids: SimklCatalogIDs
        let anime_type: String?
    }

    struct Episode: Decodable, Sendable {
        let season: Int?
        let number: Int
        let title: String?
        let tvdb_season: Int?
        let tvdb_number: Int?
    }

    let id: Int
    let progress: Double
    let paused_at: String
    let type: String
    let movie: Media?
    let show: Media?
    let episode: Episode?
    var media: Media? {
        movie ?? show
    }

    var kind: TMDBTitle.Kind {
        type == "movie" ? .movie : .tv
    }

    var date: Date? {
        PlaybackProgressConflict.date(paused_at)
    }

    var isValid: Bool {
        progress.isFinite && (0 ... 100).contains(progress) && date != nil
    }

    func matches(_ title: TMDBTitle, episode: TMDBEpisode?) -> Bool {
        guard kind == title.kind, let ids = media?.ids else { return false }
        let known = title.matchingIDs
        let same = ids
            .tmdb == String(title.id) || (ids.imdb != nil && ids.imdb == known.imdb) ||
            (ids.tvdb != nil && ids.tvdb == known.tvdb)
        guard same else { return false }
        if kind == .movie {
            return episode == nil
        }
        guard let remote = self.episode, let episode else { return false }
        return (remote.tvdb_season ?? remote.season) == episode
            .season_number && (remote.tvdb_number ?? remote.number) == episode.episode_number
    }
}

extension SimklClient {
    /// Full snapshot, not date_from: starting playback clears saved pauses without creating a new paused_at.
    func pausedPlaybacks() async throws -> [SimklPausedPlayback] {
        let items = try await libraryDecode([SimklPausedPlayback].self, path: "sync/playback", query: [
            URLQueryItem(name: "hide_watched", value: "true"), URLQueryItem(name: "limit", value: "10000"),
        ])
        // A truncated or malformed snapshot must never clear another device's cached progress.
        guard items.count < 10000, items.allSatisfy(\.isValid) else { throw TrackerAPIError.invalidResponse }
        return items
    }
}
