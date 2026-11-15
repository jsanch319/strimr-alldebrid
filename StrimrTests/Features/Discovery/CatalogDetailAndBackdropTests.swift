import Foundation
@testable import Strimr
import SwiftUI
import Testing

@MainActor
struct CatalogDetailAndBackdropTests {
    private func title(_ id: Int) -> MediaItem {
        CatalogMediaAdapter.make(title: .reference(id: id, kind: .movie), episode: nil, resume: nil)
    }

    @Test func `visible touch highlights ignore offscreen rows and explicit taps take priority`() {
        let selection = CatalogBackdropSelection()
        selection.setViewport(CGRect(x: 0, y: 0, width: 390, height: 800))
        let first = title(1), second = title(2)
        let a = UUID(), b = UUID(), offscreen = UUID()
        selection.update(first, bounds: CGRect(x: 20, y: 260, width: 120, height: 180), token: a)
        selection.update(second, bounds: CGRect(x: 20, y: 610, width: 120, height: 180), token: b)
        selection.update(title(3), bounds: CGRect(x: 450, y: 260, width: 120, height: 180), token: offscreen)
        #expect(selection.highlighted?.id == first.id)
        selection.select(second)
        #expect(selection.selected?.id == second.id)
        selection.clearTapPriority()
        #expect(selection.selected == nil)
        #expect(selection.highlighted?.id == first.id)
        selection.update(first, bounds: CGRect(x: 20, y: -250, width: 120, height: 180), token: a)
        #expect(selection.highlighted?.id == second.id)
    }

    @Test func `duplicate titles in different rows have independent visibility and screens do not share selections`() {
        let home = CatalogBackdropSelection(), myList = CatalogBackdropSelection()
        home.setViewport(CGRect(x: 0, y: 0, width: 390, height: 800))
        let visible = UUID(), hidden = UUID(), movie = title(1)
        home.update(movie, bounds: CGRect(x: 10, y: 220, width: 120, height: 180), token: visible)
        home.update(movie, bounds: CGRect(x: 10, y: 1000, width: 120, height: 180), token: hidden)
        home.remove(token: hidden)
        #expect(home.highlighted?.id == movie.id)
        home.select(movie)
        #expect(myList.selected == nil)
        #expect(EnvironmentValues().catalogBackdropSelection == nil)
        home.remove(token: visible)
        #expect(home.selected == nil)
        #expect(home.highlighted == nil)
    }

    @Test func `detail resume actions match media type season and episode and hide completed positions`() throws {
        let cache = CatalogProgressStore(defaults: TestDefaults.make())
        let movie = TMDBTitle.reference(id: 12, kind: .movie), show = TMDBTitle.reference(id: 12, kind: .tv)
        let episode = try JSONDecoder().decode(
            TMDBEpisode.self,
            from: Data(#"{"id":1,"season_number":1,"episode_number":7,"name":"Episode 7","runtime":60}"#.utf8),
        )
        let next = try JSONDecoder().decode(
            TMDBEpisode.self,
            from: Data(#"{"id":2,"season_number":1,"episode_number":8,"name":"Episode 8","runtime":60}"#.utf8),
        )
        cache.save(title: movie, episode: nil, position: 100.125, duration: 3600, finished: false, scope: "a")
        cache.save(title: show, episode: episode, position: 2160.25, duration: 3600, finished: false, scope: "a")
        let saved = CatalogDetailPlayback.savedRecord(title: show, episode: episode, records: cache.records(scope: "a"))
        #expect(saved?.resumeOffset == 2160.25)
        #expect(CatalogDetailPlayback.resumes(saved))
        #expect(CatalogDetailPlayback.remaining(title: show, episode: episode, record: saved) == RemainingTimeFormatter
            .text(
                duration: 3600,
                viewOffset: 2160.25,
            ))
        #expect(CatalogDetailPlayback
            .savedRecord(title: show, episode: next, records: cache.records(scope: "a")) == nil)
        #expect(CatalogDetailPlayback.latestEpisode(title: show, records: cache.records(scope: "a"))?
            .episode_number == 7)
        cache.save(title: show, episode: episode, position: 3600, duration: 3600, finished: true, scope: "a")
        let completed = CatalogDetailPlayback.savedRecord(
            title: show,
            episode: episode,
            records: cache.records(scope: "a"),
        )
        #expect(!CatalogDetailPlayback.resumes(completed))
        #expect(CatalogDetailPlayback.latestEpisode(title: show, records: cache.records(scope: "a")) == nil)
        #expect(CatalogDetailPlayback.savedRecord(title: movie, episode: nil, records: cache.records(scope: "a"))?
            .resumeOffset == 100.125)
    }

    @Test func `detail remaining time also supports Simkl percentage fallback and cleared records`() {
        let movie = TMDBTitle.reference(id: 1, kind: .movie)
        var remote = CatalogProgress(
            title: movie,
            episode: nil,
            position: 0,
            duration: 1800,
            completed: false,
            remotePercentage: 50,
            pendingSync: false,
            updatedAt: .distantPast,
        )
        #expect(CatalogDetailPlayback.remaining(title: movie, episode: nil, record: remote) == RemainingTimeFormatter
            .text(
                duration: 1800,
                viewOffset: 900,
            ))
        remote.locallyCleared = true
        #expect(!CatalogDetailPlayback.resumes(remote))
        #expect(CatalogDetailPlayback.remaining(title: movie, episode: nil, record: remote) == nil)
    }

    @Test func `details load country-specific certification real studios and TV runtime without fabricated metadata`(
    ) async throws {
        let stub = HTTPStub { request in
            if request.url?.path == "/3/tv/12" {
                return .json(
                    #"{"id":12,"name":"Show","episode_run_time":[60],"number_of_seasons":1,"production_companies":[{"id":3,"name":"Actual Studio"}],"content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-MA"},{"iso_3166_1":"GB","rating":"15"}]}}"#,
                )
            }
            return .json(
                #"{"id":12,"title":"Movie","runtime":120,"release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"PG-13","type":3}]}]}}"#,
            )
        }
        let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
        let show = try await client.details(.reference(id: 12, kind: .tv))
        #expect(show.certification(in: "GB") == "15")
        #expect(show.certification(in: "CA") == nil)
        #expect(show.production_companies?.first?.name == "Actual Studio")
        #expect(show.runtimeMinutes == 60)
        let movie = try await client.details(.reference(id: 12, kind: .movie))
        #expect(movie.certification(in: "US") == "PG-13")
        #expect(movie.certification(in: "GB") == nil)
        let queries = stub.requests
            .compactMap {
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "append_to_response" }?.value
            }
        #expect(queries == ["external_ids,content_ratings", "external_ids,release_dates"])
    }

    @Test func `manual watched writes reuse Simkl identity payload and reject unconfirmed titles`() async throws {
        let stub = HTTPStub { _ in .json(#"{"added":{"episodes":1},"not_found":{"shows":[]}}"#) }
        let client = SimklClient(
            session: TrackerFixtures.session,
            http: TrackerHTTP(session: stub.session),
            gate: TrackerWriteGate(spacing: .zero),
            onUpdated: { _ in },
            onInvalidated: {},
        )
        let show = TMDBTitle.reference(id: 12, kind: .tv, title: "Show")
        let episode = try JSONDecoder().decode(
            TMDBEpisode.self,
            from: Data(#"{"id":1,"season_number":2,"episode_number":7,"name":"Episode"}"#.utf8),
        )
        try await client.markCatalogWatched(show, episode: episode, at: Date())
        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/sync/history")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        let body = try #require(request.jsonBody)
        let series = try #require((body["shows"] as? [[String: Any]])?.first)
        let season = try #require((series["seasons"] as? [[String: Any]])?.first)
        #expect(season["number"] as? Int == 2)
        #expect((season["episodes"] as? [[String: Any]])?.first?["number"] as? Int == 7)
        await #expect(throws: TrackerAPIError.unavailable) { try await client.markCatalogWatched(
            show,
            episode: nil,
            at: Date(),
        ) }
        stub.respond { _ in .json(#"{"not_found":{"shows":[{"ids":{"tmdb":"12"}}]}}"#) }
        await #expect(throws: TrackerAPIError.notFound) { try await client.markCatalogWatched(
            show,
            episode: episode,
            at: Date(),
        ) }
    }

    @Test func `confirmed manual watched writes complete local resume while rejected writes leave it untouched`(
    ) async throws {
        let defaults = TestDefaults.make()
        let stub = HTTPStub { request in
            switch request.url?.path {
            case "/users/settings": .json(#"{"user":{"name":"alice"}}"#)
            case "/sync/history": .json(#"{"added":{"movies":1},"not_found":{"movies":[]}}"#)
            case "/sync/playback": .json("[]")
            case "/sync/activities": .json(#"{"all":"2026-11-15T00:00:00Z"}"#)
            default: .json("{}")
            }
        }
        let coordinator = TrackerCoordinator(
            store: TrackerAccountStore(userDefaults: defaults, secureStore: InMemorySecureStore()),
            queue: TrackerWriteQueue(userDefaults: defaults),
            makeClient: { _, session, updated, invalidated in
                SimklClient(
                    session: session,
                    http: TrackerHTTP(session: stub.session),
                    gate: TrackerWriteGate(spacing: .zero),
                    onUpdated: updated,
                    onInvalidated: invalidated,
                )
            },
        )
        coordinator.activate(profileID: "watched-test")
        await coordinator.connect(.simkl, session: TrackerFixtures.session)
        let cache = CatalogProgressStore(defaults: defaults)
        let store = DiscoveryStore(
            defaults: defaults,
            coordinator: coordinator,
            tmdb: TMDBClient(tokenProvider: { nil }),
            progress: cache,
        )
        let movie = TMDBTitle.reference(id: 12, kind: .movie)
        cache.save(title: movie, episode: nil, position: 123.125, duration: 1000, finished: false, scope: store.scope)
        try await store.markWatched(movie, episode: nil)
        #expect(cache.progress(title: movie, episode: nil, scope: store.scope)?.completed == true)
        #expect(cache.progress(title: movie, episode: nil, scope: store.scope)?.pendingSync == false)
        stub.respond { _ in .json(#"{"not_found":{"movies":[{"ids":{"tmdb":"13"}}]}}"#) }
        let rejected = TMDBTitle.reference(id: 13, kind: .movie)
        await #expect(throws: TrackerAPIError.notFound) { try await store.markWatched(rejected, episode: nil) }
        #expect(cache.progress(title: rejected, episode: nil, scope: store.scope) == nil)
    }
}
