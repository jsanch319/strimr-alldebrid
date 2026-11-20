import Foundation

/// Shared identity only. Every participant resolves metadata and authorized sources locally.
struct CatalogSharePlayItem: Codable, Hashable, Sendable {
    let tmdbID: Int
    let isTV: Bool
    let season: Int?
    let episode: Int?

    var isValid: Bool {
        tmdbID > 0 && (isTV ? ((season ?? -1) >= 0 && (episode ?? 0) > 0) : (season == nil && episode == nil))
    }

    var ratingKey: String {
        isTV ? "tv:\(tmdbID):s\(season ?? -1):e\(episode ?? -1)" : "movie:\(tmdbID)"
    }

    var mediaKind: MediaKind {
        isTV ? .episode : .movie
    }

    func matches(_ activity: StrimrWatchActivity) -> Bool {
        isValid && activity.ratingKey == ratingKey && activity.mediaKind == mediaKind &&
            activity.initialPosition.isFinite && activity.initialPosition >= 0
    }

    static func ownsSourceDismissal(expected: UUID?, current: UUID?, sessionActive: Bool) -> Bool {
        expected == nil || !sessionActive || expected == current
    }
}
