import Foundation
@testable import Strimr
import Testing

@MainActor
struct SimklWatchlistTests {
    private let session = TrackerSession(
        accessToken: "fixture",
        refreshToken: "fixture-refresh",
        expiresAt: .distantFuture,
    )
    private let movie = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie")
    private func client(_ stub: HTTPStub) -> SimklClient {
        SimklClient(
            session: session,
            http: TrackerHTTP(session: stub.session),
            gate: TrackerWriteGate(spacing: .zero),
            originGate: TrackerWriteGate(spacing: .zero),
            sleep: { _ in },
            onUpdated: { _ in },
            onInvalidated: {},
        )
    }

    private func rig(_ stub: HTTPStub) async
        -> (DiscoveryStore, CatalogProgressStore, TrackerCoordinator, UserDefaults)
    {
        let defaults = TestDefaults.make()
        let coordinator = TrackerCoordinator(
            store: TrackerAccountStore(userDefaults: defaults, secureStore: InMemorySecureStore()),
            queue: TrackerWriteQueue(userDefaults: defaults),
            makeClient: { _, session, updated, invalidated in
                SimklClient(
                    session: session,
                    http: TrackerHTTP(session: stub.session),
                    gate: TrackerWriteGate(spacing: .zero),
                    originGate: TrackerWriteGate(spacing: .zero),
                    sleep: { _ in },
                    onUpdated: updated,
                    onInvalidated: invalidated,
                )
            },
        )
        coordinator.activate(profileID: "watchlist-fixture")
        await coordinator.connect(.simkl, session: session)
        let progress = CatalogProgressStore(defaults: defaults)
        let store = DiscoveryStore(
            defaults: defaults,
            coordinator: coordinator,
            tmdb: TMDBClient(session: stub.session, tokenProvider: { "fixture" }),
            progress: progress,
        )
        return (store, progress, coordinator, defaults)
    }

    private nonisolated static func base(_ request: URLRequest) -> HTTPStub.Response {
        let path = request.url?.path ?? ""
        if path == "/users/settings" {
            return .json(#"{"user":{"name":"fixture-user"}}"#)
        }
        if path == "/sync/activities" {
            return .json(#"{"all":"2026-11-18T00:00:00Z"}"#)
        }
        if path == "/sync/playback" {
            return .json("[]")
        }
        if path ==
            "/sync/all-items/movies"
        {
            return .json(#"{"movies":[{"status":"plantowatch","movie":{"title":"Movie","ids":{"tmdb":"12"}}}]}"#)
        }
        if path.hasPrefix("/3/movie/") || path.hasPrefix("/3/tv/") {
            let id = Int(request.url?.lastPathComponent ?? "") ?? 0
            let kind = path.hasPrefix("/3/movie/") ? "movie" : "tv"
            return .json(
                "{\"id\":\(id),\"title\":\"Fixture\",\"poster_path\":\"/\(kind)-\(id).jpg\",\"backdrop_path\":\"/backdrop-\(id).jpg\"}",
            )
        }
        return .json("{}")
    }

    @Test(arguments: [TMDBTitle.Kind.movie, .tv])
    func `mutations require confirmation for the correct movie or TV namespace`(_ kind: TMDBTitle.Kind) async throws {
        let key = kind == .movie ? "movies" : "shows"
        let stub = HTTPStub { _ in
            .json(
                "{\"added\":{\"\(key)\":[{\"to\":\"plantowatch\",\"ids\":{\"tmdb\":12,\"simkl\":123}}]},\"not_found\":{\"\(key)\":[]}}",
            )
        }
        let title = TMDBTitle.reference(id: 12, kind: kind)
        let confirmed = try await client(stub).setPlanned(title, planned: true)
        #expect(confirmed?.kind == kind)
        #expect(confirmed?.isPlanned == true)
        #expect(confirmed?.media?.ids.simkl == "123")
        let body = try #require(stub.requests.first?.jsonBody)
        let sent = try #require((body[key] as? [[String: Any]])?.first)
        #expect(sent["to"] as? String == "plantowatch")
        #expect(body[kind == .movie ? "shows" : "movies"] == nil)
        stub.respond { _ in .json("{\"deleted\":{\"\(key)\":1},\"not_found\":{\"\(key)\":[]}}", statusCode: 201) }
        let removed = try await client(stub).setPlanned(title, planned: false)
        #expect(removed == nil)
        #expect(stub.requests.last?.url?.path == "/sync/history/remove")
    }

    @Test(arguments: [false, true])
    func `incomplete acknowledgements read back the actual status instead of guessing success`(
        simklOnly: Bool,
    ) async throws {
        let stub = HTTPStub { request in
            if request.httpMethod == "POST" {
                return .json(simklOnly ? #"{"added":{"movies":[{"to":"plantowatch","ids":{"simkl":777}}]}}"# :
                    #"{"added":{"movies":[{}]}}"#)
            }
            return .json(#"{"movies":[{"status":"plantowatch","movie":{"ids":{"tmdb":"12"}}}]}"#)
        }
        #expect(try await client(stub).setPlanned(movie, planned: true)?.isPlanned == true)
        #expect(stub.requests.last?.url?.path == "/sync/all-items/movies/plantowatch")
        stub.respond { request in request.httpMethod == "POST" ? .json(#"{"added":{"movies":[{}]}}"#) : .status(503) }
        await #expect(throws: SimklWatchlistError.confirmationUnavailable) { try await client(stub).setPlanned(
            movie,
            planned: true,
        ) }
    }

    @Test(arguments: [TMDBTitle.Kind.movie, .tv])
    func `canonical only acknowledgements confirm by read back and retain TMDb identity`(
        _ kind: TMDBTitle.Kind,
    ) async throws {
        let key = kind == .movie ? "movies" : "shows"
        let media = kind == .movie ? "movie" : "show"
        let stub = HTTPStub { request in
            if request.httpMethod == "POST" {
                return .json(
                    "{\"added\":{\"\(key)\":[{\"to\":\"plantowatch\",\"ids\":{\"simkl\":777}}]},\"not_found\":{\"movies\":[],\"shows\":[]}}",
                    statusCode: 201,
                )
            }
            return .json(
                "{\"\(key)\":[{\"status\":\"plantowatch\",\"\(media)\":{\"title\":\"Saved\",\"ids\":{\"simkl\":777}}}]}",
            )
        }
        let title = TMDBTitle.reference(id: 99, kind: kind)
        let result = try await client(stub).setPlanned(title, planned: true)
        let confirmed = try #require(result)
        #expect(confirmed.catalogID == title.catalogID)
        #expect(confirmed.media?.ids.simkl == "777")
        #expect(stub.requests.count == 2)
        #expect(stub.requests.last?.url?.path == "/sync/all-items/\(key)/plantowatch")
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let ids =
            try #require(((stub.requests.first?.jsonBody?[key] as? [[String: Any]])?
                    .first)?["ids"] as? [String: String])
        #expect(ids["tmdb"] == "99")
    }

    @Test(arguments: ["different-canonical", "different-tmdb", "wrong-status", "empty", "multiple-receipts"])
    func `canonical receipts never manufacture success without exact server confirmation`(_ failure: String) async {
        let stub = HTTPStub { request in
            if request.httpMethod == "POST" {
                let receipts = failure == "multiple-receipts" ?
                    #"[{"to":"plantowatch","ids":{"simkl":777}},{"to":"plantowatch","ids":{"simkl":888}}]"# :
                    #"[{"to":"plantowatch","ids":{"simkl":777}}]"#
                return .json("{\"added\":{\"movies\":\(receipts)},\"not_found\":{\"movies\":[]}}")
            }
            switch failure {
            case "different-canonical": return .json(
                    #"{"movies":[{"status":"plantowatch","movie":{"ids":{"simkl":888}}}]}"#,
                )
            case "different-tmdb": return .json(
                    #"{"movies":[{"status":"plantowatch","movie":{"ids":{"simkl":777,"tmdb":"100"}}}]}"#,
                )
            case "wrong-status": return .json(#"{"movies":[{"status":"completed","movie":{"ids":{"simkl":777}}}]}"#)
            case "multiple-receipts": return .json(
                    #"{"movies":[{"status":"plantowatch","movie":{"ids":{"simkl":777}}}]}"#,
                )
            default: return .json("{}")
            }
        }
        await #expect(throws: SimklWatchlistError.notConfirmed) {
            try await client(stub).setPlanned(.reference(id: 99, kind: .movie), planned: true)
        }
        #expect(stub.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test(arguments: [401, 403, 429])
    func `confirmation reads retain actionable authorization and quota errors`(_ status: Int) async {
        let stub = HTTPStub { request in
            if request.url?.path == "/oauth2/token" {
                return .json(#"{"error":"invalid_grant"}"#, statusCode: 400)
            }
            if request.httpMethod == "POST" {
                return .json(
                    #"{"added":{"movies":[{"to":"plantowatch","ids":{"simkl":777}}]},"not_found":{"movies":[]}}"#,
                )
            }
            return .json(status == 429 ? #"{"error":"user_limit_exceeded"}"# : "{}", statusCode: status)
        }
        let expected: TrackerAPIError = switch status {
        case 401: .sessionExpired
        case 403: .unexpected(status: 403)
        default: .rateLimited(retryAfter: 3600)
        }
        await #expect(throws: expected) {
            try await client(stub).setPlanned(.reference(id: 99, kind: .movie), planned: true)
        }
        #expect(stub.requests.filter { $0.url?.path == "/sync/add-to-list" }.count == 1)
        #expect(!SimklWatchlistError.message(expected).contains("TrackerAPIError"))
    }

    @Test(arguments: [TMDBTitle.Kind.movie, .tv])
    func `canonical save refreshes bookmark and poster and survives sync removal and restart`(
        _ kind: TMDBTitle.Kind,
    ) async throws {
        let stub = HTTPStub { Self.base($0) }
        let (store, progress, coordinator, defaults) = await rig(stub)
        await store.sync(force: true)
        let title = TMDBTitle.reference(id: 99, kind: kind)
        let key = kind == .movie ? "movies" : "shows"
        let media = kind == .movie ? "movie" : "show"
        progress.save(
            title: movie,
            episode: nil,
            position: 333.125,
            duration: 1000,
            finished: false,
            scope: store.scope,
        )
        stub.respond { request in
            if request.url?.path == "/sync/add-to-list" {
                return .json(
                    "{\"added\":{\"\(key)\":[{\"to\":\"plantowatch\",\"ids\":{\"simkl\":777}}]},\"not_found\":{\"movies\":[],\"shows\":[]}}",
                    statusCode: 201,
                )
            }
            if request.url?.path.hasPrefix("/sync/all-items/\(key)") == true {
                return .json(
                    "{\"\(key)\":[{\"status\":\"plantowatch\",\"\(media)\":{\"title\":\"Saved\",\"ids\":{\"simkl\":777}}}]}",
                )
            }
            if request.url?.path == "/sync/activities" {
                return .json(#"{"all":"2026-11-19T00:00:00Z"}"#)
            }
            return Self.base(request)
        }
        try await store.setPlanned(title, planned: true)
        let saved = try #require(store.entry(for: title))
        #expect(saved.isPlanned)
        #expect(store.title(for: saved)?.poster_path == "/\(kind.rawValue)-99.jpg")
        #expect(store.entry(for: movie)?.isPlanned == true)
        stub.respond { _ in .status(503) }
        let restored = DiscoveryStore(
            defaults: defaults,
            coordinator: coordinator,
            tmdb: TMDBClient(tokenProvider: { nil }),
            progress: progress,
        )
        await restored.sync(force: true)
        #expect(restored.entry(for: title)?.isPlanned == true)
        #expect(restored.title(for: saved)?.poster_path == "/\(kind.rawValue)-99.jpg")
        stub.respond { request in
            if request.url?.path == "/sync/history/remove" {
                return .json("{\"deleted\":{\"\(key)\":1},\"not_found\":{\"movies\":[],\"shows\":[]}}", statusCode: 201)
            }
            return .status(503)
        }
        try await restored.setPlanned(title, planned: false)
        #expect(restored.entry(for: title) == nil)
        #expect(restored.entry(for: movie)?.isPlanned == true)
        #expect(progress.progress(title: movie, episode: nil, scope: store.scope)?.resumeOffset == 333.125)
    }

    @Test(arguments: [
        "wrong-id",
        "wrong-status",
        "empty",
        "not-found",
        "quota",
        "expired",
        "server",
        "network",
        "forbidden",
    ])
    func `failed writes keep bookmark cache and exact resume positions`(_ failure: String) async {
        let stub = HTTPStub { Self.base($0) }
        let (store, progress, _, _) = await rig(stub)
        await store.sync(force: true)
        progress.save(
            title: movie,
            episode: nil,
            position: 333.125,
            duration: 1000,
            finished: false,
            scope: store.scope,
        )
        stub.respond { request in
            if request.url?.path == "/oauth2/token" {
                return .json(#"{"error":"invalid_grant"}"#, statusCode: 400)
            }
            switch failure {
            case "wrong-id": return .json(#"{"added":{"movies":[{"to":"plantowatch","ids":{"tmdb":"100"}}]}}"#)
            case "wrong-status": return .json(#"{"added":{"movies":[{"to":"watching","ids":{"tmdb":"99"}}]}}"#)
            case "not-found": return .json(#"{"not_found":{"movies":[{"ids":{"tmdb":"99"}}]}}"#)
            case "quota": return .json(#"{"error":"user_limit_exceeded"}"#, statusCode: 429)
            case "expired": return .status(401)
            case "server": return .status(503)
            case "network": throw URLError(.timedOut)
            case "forbidden": return .status(403)
            default: return .json("{}")
            }
        }
        do {
            try await store.setPlanned(.reference(id: 99, kind: .movie), planned: true); Issue
                .record("Unconfirmed mutation must fail")
        } catch { #expect(!SimklWatchlistError.message(error).contains("TrackerAPIError")) }
        #expect(store.planned.count == 1)
        #expect(store.entry(for: movie)?.isPlanned == true)
        #expect(store.entry(for: .reference(id: 99, kind: .movie)) == nil)
        #expect(progress.progress(title: movie, episode: nil, scope: store.scope)?.resumeOffset == 333.125)
    }

    @Test func `failed removal preserves the bookmark and confirmed removal preserves exact resume`() async throws {
        let stub = HTTPStub { Self.base($0) }
        let (store, progress, _, _) = await rig(stub)
        await store.sync(force: true)
        progress.save(
            title: movie,
            episode: nil,
            position: 456.125,
            duration: 1000,
            finished: false,
            scope: store.scope,
        )
        stub.respond { _ in .status(503) }
        do { try await store.setPlanned(movie, planned: false); Issue.record("Removal must not succeed on 503") }
        catch { #expect(store.entry(for: movie)?.isPlanned == true) }
        stub.respond { request in
            if request.url?.path == "/sync/history/remove" {
                return .json(
                    #"{"deleted":{"movies":1},"not_found":{"movies":[]}}"#,
                    statusCode: 201,
                )
            }
            if request.url?.path == "/sync/activities" {
                return .json(#"{"all":"2026-11-19T00:00:00Z"}"#)
            }
            if request.url?.path == "/sync/all-items/movies" {
                return .json("{}")
            }
            return Self.base(request)
        }
        try await store.setPlanned(movie, planned: false)
        #expect(store.entry(for: movie) == nil)
        #expect(progress.progress(title: movie, episode: nil, scope: store.scope)?.resumeOffset == 456.125)
        #expect(stub.requests.filter { $0.url?.path == "/sync/history/remove" }.count == 2)
    }

    @Test func `confirmed first mutation merges persisted cache and survives restart during a sync outage`(
    ) async throws {
        let stub = HTTPStub { Self.base($0) }
        let (first, progress, coordinator, defaults) = await rig(stub)
        await first.sync(force: true)
        let title = try JSONDecoder().decode(
            TMDBTitle.self,
            from: Data(#"{"id":99,"media_type":"movie","title":"New","poster_path":"/new-real-path.jpg"}"#.utf8),
        )
        let cold = DiscoveryStore(
            defaults: defaults,
            coordinator: coordinator,
            tmdb: TMDBClient(tokenProvider: { nil }),
            progress: progress,
        )
        stub.respond { request in
            if request.url?
                .path ==
                "/sync/add-to-list"
            {
                return .json(#"{"added":{"movies":[{"to":"plantowatch","ids":{"tmdb":"99"}}]}}"#)
            }
            return .status(503)
        }
        try await cold.setPlanned(title, planned: true)
        #expect(Set(cold.planned.compactMap(\.catalogID)) == ["movie:12", "movie:99"])
        let restored = DiscoveryStore(
            defaults: defaults,
            coordinator: coordinator,
            tmdb: TMDBClient(tokenProvider: { nil }),
            progress: progress,
        )
        await restored.sync(force: true)
        #expect(restored.entry(for: title)?.isPlanned == true)
        #expect(try restored.title(for: #require(restored.entry(for: title)))?.poster_path == "/new-real-path.jpg")
    }

    @Test func `posters beyond the Home batch load for movie and TV IDs and persist`() async throws {
        let movies = (1 ... 45).map { "{\"status\":\"plantowatch\",\"movie\":{\"ids\":{\"tmdb\":\"\($0)\"}}}" }
            .joined(separator: ",")
        let stub = HTTPStub { request in
            if request.url?.path == "/sync/all-items/movies" {
                return .json("{\"movies\":[\(movies)]}")
            }
            if request.url?
                .path ==
                "/sync/all-items/shows"
            {
                return .json(#"{"shows":[{"status":"plantowatch","show":{"ids":{"tmdb":"45"}}}]}"#)
            }
            return Self.base(request)
        }
        let (store, progress, coordinator, defaults) = await rig(stub)
        await store.sync(force: true)
        let film = try #require(store.entry(for: .reference(id: 45, kind: .movie)))
        let show = try #require(store.entry(for: .reference(id: 45, kind: .tv)))
        #expect(store.title(for: film)?.poster_path == nil)
        _ = await store.hydrateArtwork(for: film)
        _ = await store.hydrateArtwork(for: show)
        #expect(store.title(for: film)?.poster_path == "/movie-45.jpg")
        #expect(store.title(for: show)?.poster_path == "/tv-45.jpg")
        stub.respond { _ in .status(503) }
        let restored = DiscoveryStore(
            defaults: defaults,
            coordinator: coordinator,
            tmdb: TMDBClient(tokenProvider: { nil }),
            progress: progress,
        )
        await restored.sync(force: true)
        #expect(restored.title(for: show)?.poster_path == "/tv-45.jpg")
        #expect(restored.title(for: film)?.poster_path == "/movie-45.jpg")
    }

    @Test func `missing TMDb IDs resolve by exact external identity without cross-kind guesses`() async throws {
        let stub = HTTPStub { request in
            if request.url?.path == "/sync/all-items/movies" {
                return .json("{}")
            }
            if request.url?
                .path ==
                "/sync/all-items/shows"
            {
                return .json(
                    #"{"shows":[{"status":"plantowatch","show":{"title":"Series","ids":{"simkl":777,"imdb":"tt-fixture"}}}]}"#,
                )
            }
            if request.url?
                .path ==
                "/3/find/tt-fixture"
            {
                return .json(#"{"movie_results":[{"id":99}],"tv_results":[{"id":45,"name":"Series"}]}"#)
            }
            return Self.base(request)
        }
        let (store, _, _, _) = await rig(stub)
        await store.sync(force: true)
        let series = TMDBTitle.reference(id: 45, kind: .tv)
        #expect(store.entry(for: series)?.isPlanned == true)
        #expect(try store.title(for: #require(store.entry(for: series)))?.poster_path == "/tv-45.jpg")
        #expect(store.entry(for: .reference(id: 99, kind: .movie)) == nil)
    }
}
