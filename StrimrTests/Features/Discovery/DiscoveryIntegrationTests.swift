import Foundation
@testable import Strimr
import Testing

@MainActor
struct DiscoveryIntegrationTests {
    @Test func `movie matching rejects remakes sequels and episodes but keeps every source variant`() {
        let title = TMDBTitle.reference(id: 1, kind: .movie, title: "Dune", year: 2021)
        #expect(AllDebridTitleMatcher.matches(title: title, episode: nil, filename: "Dune.2021.1080p.WEB-DL.mkv"))
        #expect(!AllDebridTitleMatcher.matches(title: title, episode: nil, filename: "Dune.1984.2160p.mkv"))
        #expect(!AllDebridTitleMatcher.matches(title: title, episode: nil, filename: "Dune.Part.Two.2024.mkv"))
        #expect(!AllDebridTitleMatcher.matches(title: title, episode: nil, filename: "Dune.S01E01.mkv"))
        #expect(AllDebridTitleMatcher.matches(
            title: .reference(id: 2, kind: .movie, title: "1917", year: 2019),
            episode: nil,
            filename: "1917.2019.1080p.mkv",
        ))
        let files = ["Dune.2021.1080p.mkv", "Dune.2021.2160p.mkv", "Dune.1984.mkv"].enumerated()
            .map { index, filename in
                AllDebridMagnetFile(
                    id: String(index),
                    magnetID: "m",
                    filename: filename,
                    fullPath: filename,
                    size: 100,
                    link: "https://example.com/file",
                )
            }
        #expect(AllDebridTitleMatcher.sources(title: title, episode: nil, files: files, links: []).count == 2)
    }

    @Test func `TV matching requires exact show season and episode`() throws {
        let title = TMDBTitle.reference(id: 3, kind: .tv, title: "Example Show")
        let episode = try JSONDecoder().decode(
            TMDBEpisode.self,
            from: Data(#"{"id":20,"season_number":2,"episode_number":3,"name":"Episode"}"#.utf8),
        )
        #expect(AllDebridTitleMatcher.matches(
            title: title,
            episode: episode,
            filename: "Example.Show.S02E03.1080p.mkv",
        ))
        #expect(AllDebridTitleMatcher.matches(
            title: title,
            episode: episode,
            filename: "S02E03.mkv",
            context: "Example Show/Season 2",
        ))
        #expect(!AllDebridTitleMatcher.matches(
            title: .reference(id: 4, kind: .tv, title: "Example Show", year: 2020),
            episode: episode,
            filename: "Example.Show.2015.S02E03.mkv",
        ))
        #expect(!AllDebridTitleMatcher.matches(title: title, episode: episode, filename: "Example.Show.S02E03-E04.mkv"))
        #expect(!AllDebridTitleMatcher.matches(title: title, episode: episode, filename: "Example.Show.S01E03.mkv"))
        #expect(!AllDebridTitleMatcher.matches(title: title, episode: episode, filename: "Another.Show.S02E03.mkv"))
        #expect(!AllDebridTitleMatcher.matches(title: title, episode: episode, filename: "Example.Show.S02E03E04.mkv"))
    }

    @Test func `resume survives store recreation is scoped and ignores engine startup zero`() {
        let defaults = TestDefaults.make()
        let title = TMDBTitle.reference(id: 12, kind: .movie, title: "Example")
        let first = CatalogProgressStore(defaults: defaults)
        first.save(title: title, episode: nil, position: 400, duration: 1000, finished: false, scope: "alice")
        let second = CatalogProgressStore(defaults: defaults)
        second.save(title: title, episode: nil, position: 0, duration: 1000, finished: false, scope: "alice")
        #expect(second.progress(title: title, episode: nil, scope: "alice")?.position == 400)
        #expect(second.records(scope: "bob").isEmpty)
        second.save(title: title, episode: nil, position: 970, duration: 1000, finished: false, scope: "alice")
        #expect(second.progress(title: title, episode: nil, scope: "alice")?.completed == false)
        second.save(title: title, episode: nil, position: 1000, duration: 1000, finished: true, scope: "alice")
        #expect(second.progress(title: title, episode: nil, scope: "alice")?.completed == true)
        second.save(title: title, episode: nil, position: .nan, duration: nil, finished: false, scope: "alice")
        #expect(second.records(scope: "alice").count == 1)
    }

    private func client(_ stub: HTTPStub) -> SimklClient {
        SimklClient(
            session: TrackerFixtures.session,
            http: TrackerHTTP(session: stub.session),
            gate: TrackerWriteGate(spacing: .zero),
            onUpdated: { _ in },
            onInvalidated: {},
        )
    }

    @Test func `watchlist writes use per-item destinations and report unresolved titles`() async throws {
        let stub = HTTPStub { _ in .json(#"{"added":{"movies":[{}]},"not_found":{"movies":[]}}"#) }
        let client = client(stub)
        let title = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie", year: 2020)
        try await client.setPlanned(title, planned: true)
        let body = try #require(stub.requests.first?.jsonBody)
        #expect(body["to"] == nil)
        let movie = try #require((body["movies"] as? [[String: Any]])?.first)
        #expect(movie["to"] as? String == "plantowatch")
        #expect((movie["ids"] as? [String: String])?["tmdb"] == "12")
        stub.respond { _ in .json(#"{"not_found":{"movies":[{"ids":{"tmdb":"12"}}]}}"#) }
        await #expect(throws: TrackerAPIError.notFound) { try await client.setPlanned(title, planned: true) }
    }

    @Test func `sync gates pulls on activities preserves cache on failure and isolates profiles`() async throws {
        let defaults = TestDefaults.make()
        let accounts = TrackerAccountStore(userDefaults: defaults, secureStore: InMemorySecureStore())
        let stub = HTTPStub { request in
            switch request.url?.path {
            case "/users/settings": .json(#"{"user":{"name":"alice"}}"#)
            case "/sync/playback": .json("[]")
            case "/sync/activities": .json(#"{"all":"2026-11-15T00:00:00Z","movies":{"all":"2026-11-15T00:00:00Z"}}"#)
            case "/sync/all-items/movies": .json(
                    #"{"movies":[{"status":"plantowatch","movie":{"title":"Movie","year":2020,"ids":{"simkl":10,"tmdb":"12"}}}]}"#,
                )
            default: .json("{}")
            }
        }
        let coordinator = TrackerCoordinator(
            store: accounts,
            queue: TrackerWriteQueue(userDefaults: defaults),
            makeClient: { _, session, updated, invalidated in
                SimklClient(
                    session: session,
                    http: TrackerHTTP(session: stub.session),
                    onUpdated: updated,
                    onInvalidated: invalidated,
                )
            },
        )
        coordinator.activate(profileID: "alice")
        await coordinator.connect(.simkl, session: TrackerFixtures.session)
        let tmdb = TMDBClient(session: stub.session, tokenProvider: { nil })
        let store = DiscoveryStore(
            defaults: defaults,
            coordinator: coordinator,
            tmdb: tmdb,
            progress: CatalogProgressStore(defaults: defaults),
        )
        await store.sync(force: true)
        #expect(store.planned.count == 1)
        let pulls = stub.requests.filter { $0.url?.path.contains("all-items") == true }.count
        await store.sync(force: true)
        #expect(stub.requests.filter { $0.url?.path.contains("all-items") == true }.count == pulls)
        stub.respond { request in
            if request.url?.path == "/sync/playback" {
                return .json("[]")
            }
            if request.url?
                .path == "/sync/add-to-list"
            {
                return .json(#"{"added":{"movies":[{}]},"not_found":{"movies":[]}}"#)
            }
            return .json(#"{"all":"2026-11-15T00:00:00Z","movies":{"all":"2026-11-15T00:00:00Z"}}"#)
        }
        try await store.setPlanned(.reference(id: 13, kind: .movie, title: "Another Movie"), planned: true)
        #expect(store.planned.count == 2)
        #expect(stub.requests.filter { $0.url?.path.contains("all-items") == true }.count == pulls)
        stub.respond { _ in .status(503) }
        await store.sync(force: true)
        #expect(store.planned.count == 2)
        #expect(store.errorMessage != nil)
        coordinator.setEnabled(false, for: .simkl)
        await store.sync()
        #expect(store.entries.isEmpty)
        stub.respond { request in
            if request.url?.path == "/sync/playback" {
                return .json("[]")
            }
            return .json(#"{"all":"2026-11-15T00:00:00Z","movies":{"all":"2026-11-15T00:00:00Z"}}"#)
        }
        coordinator.setEnabled(true, for: .simkl)
        await store.sync()
        #expect(store.planned.count == 2)
        #expect(store.errorMessage == nil)
        coordinator.activate(profileID: "bob")
        await store.sync(force: true)
        #expect(store.entries.isEmpty)
    }
}
