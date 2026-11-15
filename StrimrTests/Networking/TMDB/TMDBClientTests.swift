import Foundation
@testable import Strimr
import Testing

@MainActor
struct TMDBClientTests {
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
        let episodes = try await client.episodes(tvID: detail.id, season: 0)
        #expect(episodes.first?.name == "Special")
        #expect(stub.requests.last?.url?.path == "/3/tv/12/season/0")
    }
}
