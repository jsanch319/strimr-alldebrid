import Foundation
@testable import Strimr
import Testing

@MainActor
struct SimklResumeTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private var clientSession: TrackerSession {
        TrackerSession(
            accessToken: "test",
            refreshToken: "test-refresh",
            expiresAt: .distantFuture,
        )
    }

    private var activities: SimklActivities {
        get throws { try decode(SimklActivities.self, #"{"all":"2026-11-15T00:00:00Z"}"#) }
    }

    private func pause(
        percent: Double = 40,
        date: String = "2026-11-15T00:00:00Z",
        episode: Bool = false,
    ) throws -> SimklPausedPlayback {
        let media = episode ?
            #""type":"episode","show":{"title":"Show","ids":{"tmdb":"12"}},"episode":{"season":2,"number":3,"title":"Episode"}"# :
            #""type":"movie","movie":{"title":"Movie","ids":{"tmdb":12}}"#
        return try decode(
            SimklPausedPlayback.self,
            "{\"id\":1,\"progress\":\(percent),\"paused_at\":\"\(date)\",\(media)}",
        )
    }

    private func metadata() -> TMDBClient {
        TMDBClient(tokenProvider: { nil })
    }

    @Test func `another device imports saved movie and episode percentages without local history`() async throws {
        let cache = CatalogProgressStore(defaults: TestDefaults.make())
        var writes = 0
        let result = try await cache.reconcile(
            paused: [pause(), pause(percent: 55, episode: true)],
            entries: [],
            scope: "device-b",
            activities: activities,
            tmdb: metadata(),
            replay: { _, _, _ in writes += 1; return true },
        )
        let records = cache.records(scope: "device-b")
        #expect(records.count == 2)
        #expect(writes == 0)
        #expect(result.unmapped == 0)
        #expect(records.first { $0.title.kind == .movie }?.fraction == 0.4)
        #expect(records.first { $0.title.kind == .tv }?.episode?.season_number == 2)
        #expect(records.first { $0.title.kind == .tv }?.episode?.episode_number == 3)
        #expect(PlaybackProgressConflict.position(percentage: 40, duration: 7200) == 2880)
        #expect(PlaybackProgressConflict.position(percentage: 40, duration: nil) == nil)
    }

    @Test func `older remote pause and expiry preserve acknowledged exact local seconds`() async throws {
        let cache = CatalogProgressStore(defaults: TestDefaults.make())
        let title = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie")
        cache.save(title: title, episode: nil, position: 700, duration: 1000, finished: false, scope: "a")
        var saved = try #require(cache.records(scope: "a").first)
        saved.pendingSync = false
        cache.replace([saved], scope: "a")
        _ = try await cache.reconcile(
            paused: [pause(percent: 20)],
            entries: [],
            scope: "a",
            activities: activities,
            tmdb: metadata(),
            replay: { _, _, _ in Issue.record("Synchronized cache must not be uploaded"); return false },
        )
        #expect(cache.records(scope: "a").first?.position == 700)
        _ = try await cache.reconcile(
            paused: [],
            entries: [],
            scope: "a",
            activities: activities,
            tmdb: metadata(),
            replay: { _, _, _ in false },
        )
        #expect(cache.records(scope: "a").first?.position == 700)
    }

    @Test func `newer offline checkpoint is replayed once and newer remote wins without upload`() async throws {
        let cache = CatalogProgressStore(defaults: TestDefaults.make())
        let title = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie")
        cache.save(title: title, episode: nil, position: 500, duration: 1000, finished: false, scope: "a")
        var replayed: [Double] = []
        _ = try await cache.reconcile(
            paused: [pause(percent: 10, date: "2000-01-01T00:00:00Z")],
            entries: [],
            scope: "a",
            activities: activities,
            tmdb: metadata(),
            replay: { _, percent, _ in replayed.append(percent); return true },
        )
        #expect(replayed == [50])
        #expect(cache.records(scope: "a").first?.pendingSync == false)
        _ = try await cache.reconcile(
            paused: [pause(percent: 30, date: "2099-01-01T00:00:00Z")],
            entries: [],
            scope: "a",
            activities: activities,
            tmdb: metadata(),
            replay: { _, _, _ in Issue.record("Newer remote must win"); return false },
        )
        #expect(cache.records(scope: "a").first?.fraction == 0.3)
    }

    @Test func `newer watched history prevents an old offline checkpoint from reopening a title`() async throws {
        let cache = CatalogProgressStore(defaults: TestDefaults.make())
        cache.save(
            title: .reference(id: 12, kind: .movie, title: "Movie"),
            episode: nil,
            position: 100,
            duration: 1000,
            finished: false,
            scope: "a",
        )
        let entry = try decode(
            SimklListEntry.self,
            #"{"status":"completed","last_watched_at":"2099-01-01T00:00:00Z","movie":{"title":"Movie","ids":{"tmdb":"12"}}}"#,
        )
        _ = try await cache.reconcile(
            paused: [],
            entries: [entry],
            scope: "a",
            activities: activities,
            tmdb: metadata(),
            replay: { _, _, _ in Issue.record("Newer watched history must win"); return false },
        )
        #expect(cache.records(scope: "a").first?.completed == true)
    }

    @Test func `shared recorder supplies checkpoints and preserves late partial playback until completion`() {
        let cache = CatalogProgressStore(defaults: TestDefaults.make())
        let title = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie")
        let recorder = cache.makeRecorder(title: title, episode: nil, scope: "a")
        recorder.record(position: 950, duration: 1000, isPaused: false)
        recorder.stop(position: 950)
        #expect(cache.records(scope: "a").first?.completed == false)
        #expect(cache.records(scope: "a").first?.pendingSync == true)
        #expect(recorder.resumePosition == 950)
        cache.acknowledge(
            TrackerPlaybackReport(
                event: .stop,
                item: TrackerItem(kind: .movie, ids: title.matchingIDs),
                progress: 95,
                date: Date(),
            ),
            scope: "a",
        )
        recorder.stop(position: 950)
        #expect(cache.records(scope: "a").first?.pendingSync == false)
        recorder.finish()
        #expect(cache.records(scope: "a").first?.completed == true)
        cache.acknowledge(
            TrackerPlaybackReport(
                event: .stop,
                item: TrackerItem(kind: .movie, ids: title.matchingIDs),
                progress: 100,
                date: Date(),
            ),
            scope: "a",
        )
        recorder.stop(position: 1000)
        #expect(cache.records(scope: "a").first?.pendingSync == false)
    }

    @Test func `existing player waits for actual duration before applying a remote percentage`() throws {
        let cache = CatalogProgressStore(defaults: TestDefaults.make())
        let title = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie")
        let recorder = cache.makeRecorder(title: title, episode: nil, scope: "a")
        let model = try PlayerViewModel(
            localMedia: .make(id: "movie:12", server: .unassigned),
            localPlaybackURL: #require(URL(string: "https://example.com/movie.mp4")),
            catalogRecorder: recorder,
            catalogResumePercentage: 40,
        )
        #expect(model.shouldResumeFromOffset)
        #expect(model.resumePosition == nil)
        model.handlePlaybackDuration(7200)
        #expect(model.resumePosition == 2880)
        model.handlePlaybackDuration(6000)
        #expect(model.resumePosition == 2400)
    }

    @Test func `exact fractional seconds survive acknowledgement relaunch and expired Simkl sessions`() async throws {
        let defaults = TestDefaults.make()
        let cache = CatalogProgressStore(defaults: defaults)
        let title = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie")
        let recorder = cache.makeRecorder(title: title, episode: nil, scope: "a")
        recorder.record(position: 125.75, duration: 1000.5, isPaused: false)
        recorder.stop(position: 126.125)
        cache.acknowledge(
            TrackerPlaybackReport(
                event: .stop,
                item: TrackerItem(kind: .movie, ids: title.matchingIDs),
                progress: 12.6,
                date: Date(),
            ),
            scope: "a",
        )
        let relaunched = CatalogProgressStore(defaults: defaults)
        _ = try await relaunched.reconcile(
            paused: [],
            entries: [],
            scope: "a",
            activities: activities,
            tmdb: metadata(),
            replay: { _, _, _ in Issue.record("Acknowledged progress must not replay"); return false },
        )
        let record = try #require(relaunched.progress(title: title, episode: nil, scope: "a"))
        #expect(record.resumeOffset == 126.125)
        #expect(record.duration == 1000.5)
        #expect(record.resumePercentage == nil)
        #expect(record.fraction == 126.125 / 1000.5)
        #expect(record.localCheckpoint?.updatedAt == record.updatedAt)
        #expect(relaunched.records(scope: "other-account").isEmpty)
    }

    @Test func `Simkl is a duration-based fallback until this device actually plays`() async throws {
        let cache = CatalogProgressStore(defaults: TestDefaults.make())
        _ = try await cache.reconcile(
            paused: [pause(percent: 32.5)],
            entries: [],
            scope: "a",
            activities: activities,
            tmdb: metadata(),
            replay: { _, _, _ in false },
        )
        let saved = try #require(cache.records(scope: "a").first)
        #expect(saved.resumeOffset == nil)
        #expect(saved.resumePercentage == 32.5)
        let model = try PlayerViewModel(
            localMedia: CatalogMediaAdapter.make(title: saved.title, episode: nil, resume: nil),
            localPlaybackURL: #require(URL(string: "https://example.com/movie.mp4")),
            catalogRecorder: cache.makeRecorder(title: saved.title, episode: nil, scope: "a"),
            catalogResumePercentage: saved.resumePercentage,
        )
        model.handlePlaybackDuration(2000)
        #expect(model.resumePosition == 650)
        model.handlePlaybackPosition(1, isScrubbing: false)
        #expect(cache.progress(title: saved.title, episode: nil, scope: "a")?.resumeOffset == nil)
        model.completeInitialCatalogResume()
        model.handlePlaybackPosition(650.25, isScrubbing: false)
        model.saveProgress()
        #expect(cache.progress(title: saved.title, episode: nil, scope: "a")?.resumeOffset == 650.25)
    }

    @Test func `exact resume waits for readiness and checkpoints buffering interruptions`() throws {
        let cache = CatalogProgressStore(defaults: TestDefaults.make())
        let title = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie")
        cache.save(title: title, episode: nil, position: 600.125, duration: 2000, finished: false, scope: "a")
        let model = try PlayerViewModel(
            localMedia: CatalogMediaAdapter.make(title: title, episode: nil, resume: 600.125),
            localPlaybackURL: #require(URL(string: "https://example.com/movie.mp4")),
            catalogRecorder: cache.makeRecorder(title: title, episode: nil, scope: "a"),
        )
        #expect(model.resumePosition == 600.125)
        model.handlePlaybackPosition(2, isScrubbing: false)
        model.saveProgress()
        #expect(cache.progress(title: title, episode: nil, scope: "a")?.position == 600.125)
        model.handlePlaybackDuration(2000)
        model.completeInitialCatalogResume()
        model.handlePlaybackPosition(610.375, isScrubbing: false)
        model.handlePlaybackState(isPaused: false, isBuffering: true)
        model.saveProgress()
        #expect(cache.progress(title: title, episode: nil, scope: "a")?.resumeOffset == 610.375)
        model.handlePlaybackPosition(611.125, isScrubbing: false)
        model.handlePlaybackState(isPaused: true, isBuffering: true)
        #expect(cache.progress(title: title, episode: nil, scope: "a")?.resumeOffset == 611.125)
        model.handleStop()
        #expect(cache.progress(title: title, episode: nil, scope: "a")?.resumeOffset == 611.125)
    }

    @Test func `completion clear and restart fence off stale pauses without sharing episode positions`() async throws {
        let cache = CatalogProgressStore(defaults: TestDefaults.make())
        let movie = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie")
        let show = TMDBTitle.reference(id: 12, kind: .tv, title: "Show")
        let episode = try decode(TMDBEpisode.self, #"{"id":1,"season_number":2,"episode_number":3,"name":"Episode"}"#)
        let next = try decode(TMDBEpisode.self, #"{"id":2,"season_number":2,"episode_number":4,"name":"Next"}"#)
        cache.save(title: show, episode: episode, position: 200.5, duration: 1000, finished: false, scope: "a")
        cache.save(title: show, episode: next, position: 300.25, duration: 1000, finished: false, scope: "a")
        cache.save(title: movie, episode: nil, position: 1000, duration: 1000, finished: true, scope: "a")
        _ = try await cache.reconcile(
            paused: [pause(date: "2000-01-01T00:00:00Z")],
            entries: [],
            scope: "a",
            activities: activities,
            tmdb: metadata(),
            replay: { _, _, _ in true },
        )
        #expect(cache.progress(title: movie, episode: nil, scope: "a")?.completed == true)
        cache.restart(title: movie, episode: nil, scope: "a")
        _ = try await cache.reconcile(
            paused: [pause(date: "2000-01-01T00:00:00Z")],
            entries: [],
            scope: "a",
            activities: activities,
            tmdb: metadata(),
            replay: { _, _, _ in true },
        )
        #expect(cache.progress(title: movie, episode: nil, scope: "a")?.resumeOffset == 0)
        #expect(cache.progress(title: show, episode: episode, scope: "a")?.resumeOffset == 200.5)
        #expect(cache.progress(title: show, episode: next, scope: "a")?.resumeOffset == 300.25)
        cache.clear(title: movie, episode: nil, scope: "a")
        _ = try await cache.reconcile(
            paused: [pause(date: "2000-01-01T00:00:00Z")],
            entries: [],
            scope: "a",
            activities: activities,
            tmdb: metadata(),
            replay: { _, _, _ in Issue.record("Cleared progress must not upload"); return false },
        )
        #expect(cache.progress(title: movie, episode: nil, scope: "a")?.locallyCleared == true)
        #expect(cache.progress(title: movie, episode: nil, scope: "a")?.resumeOffset == nil)
    }

    @Test func `progress recorded during a network replay cannot be overwritten by its acknowledgement`() async throws {
        let cache = CatalogProgressStore(defaults: TestDefaults.make())
        let title = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie")
        cache.save(title: title, episode: nil, position: 100, duration: 1000, finished: false, scope: "a")
        _ = try await cache.reconcile(
            paused: [],
            entries: [],
            scope: "a",
            activities: activities,
            tmdb: metadata(),
            replay: { _, _, _ in
                cache.save(title: title, episode: nil, position: 200.125, duration: 1000, finished: false, scope: "a")
                cache.save(
                    title: .reference(id: 99, kind: .movie),
                    episode: nil,
                    position: 55.5,
                    duration: 1000,
                    finished: false,
                    scope: "a",
                )
                return true
            },
        )
        #expect(cache.progress(title: title, episode: nil, scope: "a")?.resumeOffset == 200.125)
        #expect(cache.progress(title: title, episode: nil, scope: "a")?.pendingSync == true)
        #expect(cache.progress(title: .reference(id: 99, kind: .movie), episode: nil, scope: "a")?.resumeOffset == 55.5)
    }

    @Test func `unfinished checkpoints are not evicted by a library size cap`() throws {
        let defaults = TestDefaults.make()
        let cache = CatalogProgressStore(defaults: defaults)
        cache.save(
            title: .reference(id: 1, kind: .movie),
            episode: nil,
            position: 5.5,
            duration: 100,
            finished: false,
            scope: "a",
        )
        let seed = try #require(cache.records(scope: "a").first)
        cache.replace((1 ... 1005).map { id in
            CatalogProgress(
                title: .reference(id: id, kind: .movie),
                episode: nil,
                position: seed.position,
                duration: seed.duration,
                completed: false,
                updatedAt: seed.updatedAt,
                localCheckpoint: seed.localCheckpoint,
            )
        }, scope: "a")
        #expect(CatalogProgressStore(defaults: defaults).records(scope: "a").count == 1005)
    }

    @Test func `Simkl saved playback reads are authenticated and catalog min_progress is in URL`() async throws {
        let stub = HTTPStub { request in
            request.url?.path == "/sync/playback" ? .json("[]") : .json("{}")
        }
        let client = SimklClient(
            session: clientSession,
            http: TrackerHTTP(session: stub.session),
            gate: TrackerWriteGate(spacing: .zero),
            onUpdated: { _ in },
            onInvalidated: {},
        )
        #expect(try await client.pausedPlaybacks().isEmpty)
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test")
        let channel = TrackerPlaybackChannel(
            client: client,
            isAvailable: { true },
            onFailure: { _, _ in Issue.record("Unexpected delivery failure") },
        )
        let delivered = await channel.sendAndWait(TrackerPlaybackReport(
            event: .stop,
            item: TrackerFixtures.movie,
            progress: 95,
            date: Date(),
            minimumProgress: 100,
        ))
        #expect(delivered)
        let url = try #require(stub.requests.last?.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "min_progress" && $0.value == "100" } == true)
        #expect(stub.requests.last?.jsonBody?["min_progress"] == nil)
        stub.respond { _ in .json("{}") }
        await #expect(throws: TrackerAPIError.invalidResponse) { try await client.pausedPlaybacks() }
    }
}
