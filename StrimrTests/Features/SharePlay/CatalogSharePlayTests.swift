import Foundation
@testable import Strimr
import Testing

struct CatalogSharePlayTests {
    private func activity(_ item: CatalogSharePlayItem) -> StrimrWatchActivity {
        StrimrWatchActivity(
            activityID: UUID(),
            provider: .plex,
            serverIdentifier: "tmdb-catalog",
            ratingKey: item.ratingKey,
            mediaKind: item.mediaKind,
            title: "Title",
            initialPosition: 620.125,
            catalog: item,
        )
    }

    @Test func `catalog identities distinguish movie series season and episode`() {
        let movie = CatalogSharePlayItem(tmdbID: 12, isTV: false, season: nil, episode: nil)
        let episode = CatalogSharePlayItem(tmdbID: 12, isTV: true, season: 1, episode: 2)
        let other = CatalogSharePlayItem(tmdbID: 12, isTV: true, season: 1, episode: 3)
        #expect(movie.ratingKey != episode.ratingKey)
        #expect(episode.ratingKey != other.ratingKey)
        #expect(episode.matches(activity(episode)))
        #expect(!other.matches(activity(episode)))
    }

    @Test func `series without an exact episode never becomes a playable party`() {
        #expect(!CatalogSharePlayItem(tmdbID: 12, isTV: true, season: nil, episode: nil).isValid)
        #expect(!CatalogSharePlayItem(tmdbID: 12, isTV: true, season: 1, episode: 0).isValid)
        #expect(!CatalogSharePlayItem(tmdbID: 0, isTV: false, season: nil, episode: nil).isValid)
        #expect(CatalogSharePlayItem(tmdbID: 12, isTV: true, season: 0, episode: 1).isValid)
    }

    @Test func `activity metadata shares identity and time without playback URLs or account credentials`() throws {
        let item = CatalogSharePlayItem(tmdbID: 12, isTV: true, season: 1, episode: 2)
        let data = try JSONEncoder().encode(activity(item))
        let roundTrip = try JSONDecoder().decode(StrimrWatchActivity.self, from: data)
        #expect(roundTrip.catalog == item)
        #expect(roundTrip.initialPosition == 620.125)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let catalog = try #require(object["catalog"] as? [String: Any])
        #expect(Set(catalog.keys) == ["tmdbID", "isTV", "season", "episode"])
        #expect(!String(decoding: data, as: UTF8.self).contains("https://"))
    }

    @Test func `old media server activities decode without a catalog payload`() throws {
        let legacy = StrimrWatchActivity(
            activityID: UUID(),
            provider: .jellyfin,
            serverIdentifier: "local-server",
            ratingKey: "item",
            mediaKind: .movie,
            title: "Movie",
            initialPosition: 0,
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(StrimrWatchActivity.self, from: data)
        #expect(decoded.catalog == nil)
        #expect(decoded.serverIdentifier == "local-server")
    }
}
