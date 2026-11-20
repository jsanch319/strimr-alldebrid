import Foundation
@testable import Strimr
import Testing

@MainActor
struct TMDBClientTests {
    @Test func `title logos use typed images endpoints language preferences PNGs and cached authenticated requests`(
    ) async throws {
        for kind in [TMDBTitle.Kind.movie, .tv] {
            let stub = HTTPStub { _ in
                .json(
                    #"{"logos":[{"file_path":"/english.png","iso_639_1":"en","width":2000,"height":600},{"file_path":"/french.png","iso_639_1":"fr","width":1000,"height":400},{"file_path":"/neutral.png","width":1800,"height":300},{"file_path":"/opaque.jpg","iso_639_1":"fr","width":3000,"height":800},{"file_path":"/german.png","iso_639_1":"de","width":3000,"height":800}]}"#,
                )
            }
            let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
            let logos = try await client.titleLogos(id: 42, kind: kind, language: "fr-FR")
            #expect(logos.map(\.file_path) == ["/french.png", "/english.png", "/neutral.png", "/german.png"])
            #expect(try await client.titleLogos(id: 42, kind: kind, language: "fr-FR") == logos)
            #expect(stub.requests.count == 1)
            let request = try #require(stub.requests.first)
            #expect(request.url?.path == "/3/\(kind.rawValue)/42/images")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            let query = try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.contains { $0.name == "include_image_language" || $0.name == "language" } == false)
            let germanOnly = logos.filter { $0.iso_639_1 == "de" }
            #expect(TMDBClient.TitleLogo.preferred(germanOnly, language: "en").first?.file_path == "/german.png")
            #expect(try await client.titleLogos(id: 0, kind: kind).isEmpty)
            #expect(stub.requests.count == 1)
        }
    }

    @Test func `provider discovery scopes subscriptions to region and preserves TV identity`() async throws {
        let stub = HTTPStub { _ in
            .json(#"{"results":[{"id":12,"name":"Series"}],"total_results":1,"total_pages":1}"#)
        }
        let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
        let result = try await client.providerTitles(ids: [9, 8], kind: .tv, region: "GB", page: 2)
        #expect(result.results.first?.catalogID == "tv:12")
        let url = try #require(stub.requests.first?.url)
        #expect(url.path == "/3/discover/tv")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "with_watch_providers" }?.value == "8|9")
        #expect(query.first { $0.name == "watch_region" }?.value == "GB")
        #expect(query.first { $0.name == "with_watch_monetization_types" }?.value == "flatrate")
        #expect(query.first { $0.name == "page" }?.value == "2")
        let empty = try await client.providerTitles(ids: [], kind: .movie, region: "GB")
        #expect(empty.results.isEmpty)
        #expect(stub.requests.count == 1)
    }

    @Test func `genre discovery preserves media type filters paging and unrestricted catalog access`() async throws {
        for kind in [TMDBTitle.Kind.movie, .tv] {
            let stub = HTTPStub { _ in
                .json(#"{"results":[{"id":12,"title":"Film","name":"Series"}],"total_pages":4}"#)
            }
            let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
            for sort in TMDBClient.GenreSort.allCases {
                let result = try await client.genreTitles(genreID: 18, kind: kind, sort: sort, page: 2)
                #expect(result.results.first?.catalogID == "\(kind.rawValue):12")
                #expect(result.total_pages == 4)
                let url = try #require(stub.requests.last?.url)
                #expect(url.path == "/3/discover/\(kind.rawValue)")
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(query.first { $0.name == "with_genres" }?.value == "18")
                #expect(query.first { $0.name == "page" }?.value == "2")
                #expect(query.first { $0.name == "sort_by" }?
                    .value == (sort == .popular ? "popularity.desc" : "vote_average.desc"))
                #expect(query.first { $0.name == "vote_count.gte" }?.value == (sort == .topRated ? "100" : nil))
                #expect(!query.contains { $0.name == "with_watch_providers" || $0.name == "watch_region" })
            }
            #expect(stub.requests.count == 2)
        }
    }

    @Test func `direct catalog requests use bearer authentication and cache results`() async throws {
        let stub = HTTPStub { _ in .json(#"{"results":[{"id":12,"name":"Example TV"}]}"#) }
        let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
        let first = try await client.feed(.popularTV)
        let second = try await client.feed(.popularTV)
        #expect(first.first?.catalogID == "tv:12")
        #expect(second.first?.catalogID == "tv:12")
        #expect(stub.requests.count == 1)
        let request = try #require(stub.requests.first)
        #expect(request.url?.host == "api.themoviedb.org")
        #expect(request.url?.path == "/3/tv/popular")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.url?.absoluteString.contains("test-token") == false)
    }

    @Test func `search excludes people and preserves colliding movie and TV IDs`() async throws {
        let stub = HTTPStub { _ in
            .json(
                #"{"results":[{"id":1,"media_type":"person","name":"Person"},{"id":2,"media_type":"tv","name":"Show"},{"id":2,"media_type":"movie","title":"Film"}]}"#,
            )
        }
        let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
        let titles = try await client.search("a&b+c")
        #expect(titles.map(\.catalogID) == ["tv:2", "movie:2"])
        let url = try #require(stub.requests.first?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "query" })?.value == "a&b+c")
    }

    @Test func `rate limiting blocks subsequent network requests`() async throws {
        let stub = HTTPStub { _ in .init(statusCode: 429, headers: ["Retry-After": "120"]) }
        let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
        for feed in [TMDBClient.Feed.popularMovies, .popularTV] {
            do {
                _ = try await client.feed(feed)
                Issue.record("Expected rate limit")
            } catch let TMDBError.rateLimited(date) {
                #expect(date.timeIntervalSinceNow > 100)
            }
        }
        #expect(stub.requests.count == 1)
    }

    @Test func `missing credential never sends a request`() async throws {
        let stub = HTTPStub()
        let client = TMDBClient(session: stub.session, tokenProvider: { nil })
        await #expect(throws: TMDBError.self) { try await client.feed(.upcoming) }
        #expect(stub.requests.isEmpty)
    }

    @Test func `TV details preserve type and all seasons including specials`() async throws {
        let stub = HTTPStub { request in
            if request.url?.path == "/3/tv/12" {
                return .json(
                    #"{"id":12,"name":"Show","seasons":[{"id":10,"season_number":0,"name":"Specials","episode_count":1},{"id":11,"season_number":1,"name":"Season 1","episode_count":1}],"external_ids":{"imdb_id":"tt123","tvdb_id":99}}"#,
                )
            }
            return .json(#"{"episodes":[{"id":22,"episode_number":1,"season_number":0,"name":"Special"}]}"#)
        }
        let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
        let title = try JSONDecoder().decode(TMDBTitle.self, from: Data(#"{"id":12,"media_type":"tv"}"#.utf8))
        let detail = try await client.details(title)
        #expect(detail.catalogID == "tv:12")
        #expect(detail.seasons?.map(\.season_number) == [0, 1])
        #expect(detail.external_ids?.imdb_id == "tt123")
        #expect(detail.matchingIDs.tmdb == "12")
        #expect(detail.trackerItem() == nil)
        let episodes = try await client.episodes(tvID: detail.id, season: 0)
        let episode = try #require(episodes.first)
        #expect(episode.name == "Special")
        let tracked = try #require(detail.trackerItem(episode: episode))
        #expect(tracked.ids.tmdb == "12")
        #expect(tracked.season == 0)
        #expect(tracked.episode == 1)
        #expect(stub.requests.last?.url?.path == "/3/tv/12/season/0")
    }
}
