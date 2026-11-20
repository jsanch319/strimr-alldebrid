import Foundation
@testable import Strimr
import Testing

@MainActor
struct SimklSyncTests {
    private let session = TrackerSession(
        accessToken: "fixture-access",
        refreshToken: "fixture-refresh",
        expiresAt: .distantFuture,
    )

    private func client(
        _ stub: HTTPStub,
        updated: @escaping (TrackerSession) -> Void = { _ in },
        invalidated: @escaping () -> Void = {},
    ) -> SimklClient {
        SimklClient(
            session: session,
            http: TrackerHTTP(session: stub.session),
            gate: TrackerWriteGate(spacing: .zero),
            originGate: TrackerWriteGate(spacing: .zero),
            sleep: { _ in },
            onUpdated: updated,
            onInvalidated: invalidated,
        )
    }

    private func rig(_ stub: HTTPStub) async -> (DiscoveryStore, CatalogProgressStore, TrackerCoordinator) {
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
        coordinator.activate(profileID: "simkl-sync-test")
        await coordinator.connect(.simkl, session: session)
        let progress = CatalogProgressStore(defaults: defaults)
        return (
            DiscoveryStore(
                defaults: defaults,
                coordinator: coordinator,
                tmdb: TMDBClient(tokenProvider: { nil }),
                progress: progress,
            ),
            progress,
            coordinator,
        )
    }

    private nonisolated static func successful(_ request: URLRequest) -> HTTPStub.Response {
        switch request.url?.path {
        case "/users/settings": .json(#"{"user":{"name":"fixture-user"}}"#)
        case "/sync/activities": .json(#"{"all":"2026-11-18T00:00:00Z"}"#)
        case "/sync/all-items/movies": .json(
                #"{"movies":[{"status":"plantowatch","movie":{"title":"Fixture","ids":{"tmdb":"12"}}}]}"#,
            )
        case "/sync/playback": .json("[]")
        default: .json("{}")
        }
    }

    @Test func `successful unchanged sync retains lists and avoids redundant playback pulls`() async {
        let stub = HTTPStub { Self.successful($0) }
        let (store, _, _) = await rig(stub)
        await store.sync(force: true)
        await store.sync(force: true)
        #expect(store.entries.count == 1)
        #expect(store.errorMessage == nil)
        #expect(stub.requests.count { $0.url?.path == "/sync/playback" } == 1)
        #expect(stub.requests.count { $0.url?.path == "/sync/all-items/movies" } == 1)
    }

    @Test func `expired authorization preserves cache and exact seconds and requests reconnect once`() async {
        let stub = HTTPStub { Self.successful($0) }
        let (store, progress, coordinator) = await rig(stub)
        await store.sync(force: true)
        let title = TMDBTitle.reference(id: 12, kind: .movie)
        progress.save(
            title: title,
            episode: nil,
            position: 716.125,
            duration: 3600,
            finished: false,
            scope: store.scope,
        )
        stub.respond { request in
            request.url?.path == "/oauth2/token" ? .json(#"{"error":"invalid_grant"}"#, statusCode: 400) : .status(401)
        }
        await store.sync(force: true)
        await store.sync(force: true)
        #expect(coordinator.state(for: .simkl).settings.needsReconnect)
        #expect(store.entries.count == 1)
        #expect(store.errorMessage?.contains("Reconnect Simkl") == true)
        #expect(progress.progress(title: title, episode: nil, scope: store.scope)?.resumeOffset == 716.125)
        #expect(stub.requests.count { $0.url?.path == "/oauth2/token" } == 1)
    }

    @Test func `reconnection refreshes immediately instead of retaining an old authorization backoff`() async {
        let stub = HTTPStub { Self.successful($0) }
        let (store, _, coordinator) = await rig(stub)
        await store.sync(force: true)
        stub.respond { request in
            request.url?.path == "/oauth2/token" ? .json(#"{"error":"invalid_grant"}"#, statusCode: 400) : .status(401)
        }
        await store.sync(force: true)
        #expect(coordinator.state(for: .simkl).settings.needsReconnect)
        stub.respond { Self.successful($0) }
        await coordinator.connect(.simkl, session: session)
        let before = stub.requests.count
        await store.sync(force: true)
        #expect(!coordinator.state(for: .simkl).settings.needsReconnect)
        #expect(store.errorMessage == nil)
        #expect(stub.requests.count > before)
        #expect(store.entries.count == 1)
    }

    @Test func `network and malformed snapshots cannot zero or erase movie and episode checkpoints`() async {
        for malformed in [false, true] {
            let stub = HTTPStub { Self.successful($0) }
            let (store, progress, _) = await rig(stub)
            await store.sync(force: true)
            let movie = TMDBTitle.reference(id: 12, kind: .movie)
            let show = TMDBTitle.reference(id: 13, kind: .tv)
            let episode = TMDBEpisode(
                id: 100,
                episode_number: 7,
                season_number: 2,
                name: "Episode",
                overview: "",
                air_date: nil,
                still_path: nil,
                runtime: 45,
                vote_average: nil,
            )
            progress.save(
                title: movie,
                episode: nil,
                position: 789.625,
                duration: 7200,
                finished: false,
                scope: store.scope,
            )
            progress.save(
                title: show,
                episode: episode,
                position: 420.125,
                duration: 2700,
                finished: false,
                scope: store.scope,
            )
            stub.respond { request in
                if malformed {
                    if request.url?.path == "/sync/activities" {
                        return .json(#"{"all":"2026-11-19T00:00:00Z"}"#)
                    }
                    if request.url?.path == "/sync/playback" {
                        return .json("not-json")
                    }
                    return Self.successful(request)
                }
                throw URLError(.networkConnectionLost)
            }
            let before = stub.requests.count
            await store.sync(force: true)
            #expect(stub.requests.count - before == (malformed ? 4 : 3))
            #expect(store.entries.count == 1)
            #expect(progress.progress(title: movie, episode: nil, scope: store.scope)?.resumeOffset == 789.625)
            #expect(progress.progress(title: show, episode: episode, scope: store.scope)?.resumeOffset == 420.125)
        }
    }

    @Test func `temporary server failures retry reads twice then recover without refreshing credentials`() async throws {
        let counter = Counter()
        let stub = HTTPStub { _ in counter.next() <= 2 ? .status(503) : .json(#"{"all":null}"#) }
        let value = try await client(stub).activities()
        #expect(value.all == nil)
        #expect(stub.requests.count == 3)
        #expect(stub.requests.allSatisfy { $0.url?.path == "/sync/activities" })
    }

    @Test func `daily quota holds prevent repeated requests and burst limits retry briefly`() async throws {
        let stub = HTTPStub { _ in
            HTTPStub.Response(
                statusCode: 429,
                headers: ["Retry-After": "3600"],
                body: Data(#"{"error":"user_limit_exceeded"}"#.utf8),
            )
        }
        let api = client(stub)
        await #expect(throws: TrackerAPIError.rateLimited(retryAfter: 3600)) {
            try await api.activities()
        }
        do { _ = try await api.activities(); Issue.record("Quota hold must not send again") }
        catch { #expect(SimklSyncFailure.category(error) == "rate_limit") }
        #expect(stub.requests.count == 1)
        let counter = Counter()
        let burst = HTTPStub { _ in
            counter.next() == 1 ? .json(#"{"error":"rate_limit"}"#, statusCode: 429) : .json("{}")
        }
        _ = try await client(burst).activities()
        #expect(burst.requests.count == 2)
    }

    @Test func `a valid Simkl refresh retries once and persists rotated credentials`() async throws {
        let stub = HTTPStub { request in
            if request.url?.path == "/oauth2/token" {
                return .json(#"{"access_token":"fixture-new","refresh_token":"fixture-rotated","expires_in":604800}"#)
            }
            return request
                .value(forHTTPHeaderField: "Authorization") == "Bearer fixture-new" ? .json("{}") : .status(401)
        }
        var updated: [TrackerSession] = []
        var invalidated = 0
        _ = try await client(stub, updated: { updated.append($0) }, invalidated: { invalidated += 1 }).activities()
        #expect(updated.map(\.refreshToken) == ["fixture-rotated"])
        #expect(invalidated == 0)
        #expect(stub.requests.map(\.url?.path) == ["/sync/activities", "/oauth2/token", "/sync/activities"])
    }

    @Test func `a renewed but rejected token invalidates once and does not retry invalid credentials`() async {
        let stub = HTTPStub { request in
            request.url?
                .path == "/oauth2/token" ?
                .json(#"{"access_token":"fixture-new","refresh_token":"fixture-renewed","expires_in":604800}"#) :
                .status(401)
        }
        var invalidated = 0
        let api = client(stub, invalidated: { invalidated += 1 })
        for _ in 0 ..< 2 {
            await #expect(throws: TrackerAPIError.sessionExpired) { try await api.activities() }
        }
        #expect(invalidated == 1)
        #expect(stub.requests.count == 3)
    }

    @Test func `failed initial account validation cannot overwrite the reconnect flag`() async {
        let stub = HTTPStub { request in
            request.url?.path == "/oauth2/token" ? .json(#"{"error":"invalid_grant"}"#, statusCode: 400) : .status(401)
        }
        let (_, _, coordinator) = await rig(stub)
        #expect(coordinator.state(for: .simkl).settings.needsReconnect)
        #expect(!coordinator.state(for: .simkl).isConnected)
    }

    @Test func `legacy numeric error zero is rate limiting in the current toolchain`() {
        #expect((TrackerAPIError.rateLimited(retryAfter: nil) as NSError).code == 0)
        #expect((TrackerAPIError.rateLimited(retryAfter: 12) as NSError).code == 0)

        #expect(SimklSyncFailure.retryDelay(TrackerAPIError.sessionExpired, attempt: 0) == nil)
        #expect(SimklSyncFailure.retryDelay(TrackerAPIError.invalidResponse, attempt: 0) == nil)
        #expect(SimklSyncFailure.message(TrackerAPIError.server(status: 503), consecutiveFailures: 1) == nil)
        #expect(SimklSyncFailure.message(TrackerAPIError.sessionExpired, consecutiveFailures: 1)?
            .contains("Reconnect") == true)
    }
}

private final nonisolated class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.withLock { value += 1; return value }
    }
}
