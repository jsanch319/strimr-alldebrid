import Foundation
@testable import Strimr
import Testing

@MainActor
struct NativeHomeAdapterTests {
    private func stores() -> (CatalogHomeData, CatalogProgressStore, DiscoveryStore) {
        let defaults = TestDefaults.make()
        let progress = CatalogProgressStore(defaults: defaults)
        let coordinator = TrackerCoordinator(
            isDisabled: true,
            store: TrackerAccountStore(userDefaults: defaults, secureStore: InMemorySecureStore()),
            queue: TrackerWriteQueue(userDefaults: defaults),
        )
        let discovery = DiscoveryStore(defaults: defaults, coordinator: coordinator, progress: progress)
        return (CatalogHomeData(discovery: discovery, progress: progress), progress, discovery)
    }

    private func episode(season: Int, number: Int) throws -> TMDBEpisode {
        try JSONDecoder().decode(TMDBEpisode.self, from: Data(
            "{\"id\":1,\"season_number\":\(season),\"episode_number\":\(number),\"name\":\"Actual episode\"}".utf8,
        ))
    }

    @Test func `Continue Watching labels use only the actual resume episode`() throws {
        let show = TMDBTitle.reference(id: 12, kind: .tv)
        for (season, number) in [(1, 1), (1, 7), (2, 10), (0, 1)] {
            let media = try CatalogMediaAdapter.make(
                title: show,
                episode: episode(season: season, number: number),
                resume: 123.25,
            )
            #expect(media.continueWatchingEpisodeLabel == "S\(season) · E\(number)")
            #expect(media.continueWatchingEpisodeCaption == "S\(season) · E\(number) — Actual episode")
        }
        #expect(CatalogMediaAdapter.make(title: show, episode: nil, resume: nil).continueWatchingEpisodeLabel == nil)
        #expect(CatalogMediaAdapter.make(title: .reference(id: 12, kind: .movie), episode: nil, resume: 123)
            .continueWatchingEpisodeLabel == nil)
        #expect(try CatalogMediaAdapter.make(title: show, episode: episode(season: 1, number: 0), resume: 123)
            .continueWatchingEpisodeLabel == nil)
    }

    @Test func `TMDb metadata supplies the correct resume episode title without using another episode`() async throws {
        let stub = HTTPStub { request in
            #expect(request.url?.path == "/3/tv/12/season/2")
            return .json(
                #"{"episodes":[{"id":1,"season_number":2,"episode_number":9,"name":"Wrong episode"},{"id":2,"season_number":2,"episode_number":10,"name":"The Correct Episode Title"}]}"#,
            )
        }
        let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
        let episodes = try await client.episodes(tvID: 12, season: 2)
        let actual = try #require(episodes.first { $0.episode_number == 10 })
        let media = CatalogMediaAdapter.make(
            title: .reference(id: 12, kind: .tv, title: "Show Name"),
            episode: actual,
            resume: 123.456,
        )
        #expect(media.continueWatchingEpisodeCaption == "S2 · E10 — The Correct Episode Title")
        #expect(media.grandparentTitle == "Show Name")
        #expect(media.viewOffset == 123.456)
        #expect(CatalogMediaAdapter.make(title: .reference(id: 12, kind: .movie), episode: nil, resume: 123)
            .continueWatchingEpisodeCaption == nil)
    }

    @Test func `dismissal persists independently from resume data and account scope`() throws {
        let defaults = TestDefaults.make(), movie = TMDBTitle.reference(id: 12, kind: .movie)
        let progress = CatalogProgressStore(defaults: defaults)
        progress.save(title: movie, episode: nil, position: 123.456, duration: 3600, finished: false, scope: "a")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(progress.records(scope: "a"))
        progress.dismissFromContinueWatching(title: movie, scope: "a")
        #expect(progress.continueWatchingRecords(scope: "a").isEmpty)
        #expect(try encoder.encode(progress.records(scope: "a")) == original)
        let reopened = CatalogProgressStore(defaults: defaults)
        #expect(reopened.continueWatchingRecords(scope: "a").isEmpty)
        #expect(reopened.progress(title: movie, episode: nil, scope: "a")?.resumeOffset == 123.456)
        reopened.save(title: movie, episode: nil, position: 10, duration: 3600, finished: false, scope: "b")
        #expect(reopened.continueWatchingRecords(scope: "b").count == 1)
    }

    @Test func `only a new validated playback session restores a dismissed show including a new episode`() throws {
        let progress = CatalogProgressStore(defaults: TestDefaults.make())
        let show = TMDBTitle.reference(id: 12, kind: .tv)
        let first = try episode(season: 1, number: 7), next = try episode(season: 1, number: 8)
        let running = progress.makeRecorder(title: show, episode: first, scope: "a")
        running.record(position: 500.125, duration: 3600, isPaused: false)
        progress.dismissFromContinueWatching(title: show, scope: "a")
        running.record(position: 501.25, duration: 3600, isPaused: false)
        #expect(progress.continueWatchingRecords(scope: "a").isEmpty)
        progress.restart(title: show, episode: next, scope: "a")
        let fresh = progress.makeRecorder(title: show, episode: next, scope: "a")
        fresh.record(position: 0, duration: 3600, isPaused: false)
        #expect(progress.continueWatchingRecords(scope: "a").isEmpty)
        fresh.record(position: 1.25, duration: 3600, isPaused: false)
        let records = progress.continueWatchingRecords(scope: "a")
        #expect(records.count == 1)
        #expect(records.first?.episode?.episode_number == 8)
        #expect(records.first?.resumeOffset == 1.25)
        #expect(progress.progress(title: show, episode: first, scope: "a")?.resumeOffset == 501.25)
    }

    @Test func `Continue Watching keeps newest title once and hides older episodes after completion`() throws {
        let progress = CatalogProgressStore(defaults: TestDefaults.make())
        let show = TMDBTitle.reference(id: 12, kind: .tv), movie = TMDBTitle.reference(id: 12, kind: .movie)
        let first = try episode(season: 1, number: 1), next = try episode(season: 2, number: 10)
        progress.save(title: show, episode: first, position: 400, duration: 3600, finished: false, scope: "a")
        progress.save(title: movie, episode: nil, position: 200, duration: 3600, finished: false, scope: "a")
        progress.save(title: show, episode: next, position: 800.5, duration: 3600, finished: false, scope: "a")
        let records = progress.continueWatchingRecords(scope: "a")
        #expect(records.count == 2)
        #expect(records.first?.episode?.episode_number == 10)
        #expect(records.last?.title.kind == .movie)
        progress.save(title: show, episode: next, position: 3600, duration: 3600, finished: true, scope: "a")
        #expect(progress.continueWatchingRecords(scope: "a").map(\.title.catalogID) == [movie.catalogID])
    }

    @Test func `Home dismissal removes only Continue Watching immediately`() throws {
        let (home, progress, discovery) = stores()
        let movie = TMDBTitle.reference(id: 12, kind: .movie)
        progress.save(
            title: movie,
            episode: nil,
            position: 123.456,
            duration: 3600,
            finished: false,
            scope: discovery.scope,
        )
        let hub = try #require(home.rows.first(where: { $0.kind == .continueWatching })?.hub)
        let card = try #require(hub.items.first?.playableItem)
        let otherRows = home.rows.filter { $0.kind != .continueWatching }.map(\.id)
        let revision = progress.revision
        home.dismissFromContinueWatching(card)
        #expect(progress.revision > revision)
        #expect(!home.rows.contains { $0.kind == .continueWatching })
        #expect(home.items(for: hub).isEmpty) // Expanded view cannot resurrect the last dismissed card.
        #expect(home.rows.filter { $0.kind != .continueWatching }.map(\.id) == otherRows)
        #expect(progress.progress(title: movie, episode: nil, scope: discovery.scope)?.resumeOffset == 123.456)
    }

    @Test func `dismissal still applies when sync replaces the card while its menu is open`() throws {
        let (home, progress, discovery) = stores()
        let show = TMDBTitle.reference(id: 12, kind: .tv)
        let old = try episode(season: 1, number: 7), next = try episode(season: 2, number: 10)
        progress.save(
            title: show,
            episode: old,
            position: 123.456,
            duration: 3600,
            finished: false,
            scope: discovery.scope,
        )
        let menuCard = try #require(home.rows.first(where: { $0.kind == .continueWatching })?.items.first?.playableItem)
        progress.replace([], scope: discovery.scope) // Old remote pause disappears during a refresh.
        home.dismissFromContinueWatching(menuCard)
        progress.save(
            title: show,
            episode: next,
            position: 555.125,
            duration: 3600,
            finished: false,
            scope: discovery.scope,
        )
        #expect(!home.rows.contains { $0.kind == .continueWatching })
        #expect(progress.progress(title: show, episode: next, scope: discovery.scope)?.resumeOffset == 555.125)
    }

    @Test func `Continue Watching reuses native media captions duration and landscape rows`() throws {
        let (home, progress, discovery) = stores()
        let title = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie", year: 2020)
        progress.save(
            title: title,
            episode: nil,
            position: 900,
            duration: 3600,
            finished: false,
            scope: discovery.scope,
        )
        let row = try #require(home.rows.first { $0.id == "catalog:continue" })
        #expect(row.kind == .continueWatching)
        #expect(row.style == .landscape)
        let media = try #require(row.items.first?.playableItem)
        #expect(media.duration == 3600)
        #expect(media.viewOffset == 900)
        #expect(media.viewProgressPercentage == 25)
        #expect(media.remainingTimeText == RemainingTimeFormatter.text(duration: 3600, viewOffset: 900))
        #expect(media.remainingTimeText?.contains("%") == false)
    }

    @Test func `TV progress uses the combined native row with episode metadata`() throws {
        let (home, progress, discovery) = stores()
        let title = TMDBTitle.reference(id: 12, kind: .tv, title: "Show")
        let episode = try JSONDecoder().decode(
            TMDBEpisode.self,
            from: Data(#"{"id":1,"season_number":2,"episode_number":3,"name":"Episode","runtime":30}"#.utf8),
        )
        progress.save(
            title: title,
            episode: episode,
            position: 600,
            duration: 1800,
            finished: false,
            scope: discovery.scope,
        )
        let row = try #require(home.rows.first { $0.id == "catalog:continue" })
        let media = try #require(row.items.first?.playableItem)
        #expect(media.type == .episode)
        #expect(media.grandparentTitle == "Show")
        #expect(media.parentIndex == 2)
        #expect(media.index == 3)
        #expect(media.remainingTimeText == RemainingTimeFormatter.text(duration: 1800, viewOffset: 600))
        #expect(home.rows.filter { $0.kind == .continueWatching }.count == 1)
    }

    @Test func `mixed progress appears once above discovery without raw file rows`() throws {
        let (home, progress, discovery) = stores()
        let movie = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie")
        let show = TMDBTitle.reference(id: 12, kind: .tv, title: "Show")
        let episode = try JSONDecoder().decode(
            TMDBEpisode.self,
            from: Data(#"{"id":1,"season_number":1,"episode_number":2,"name":"Episode"}"#.utf8),
        )
        progress.save(
            title: movie,
            episode: nil,
            position: 600,
            duration: 3600,
            finished: false,
            scope: discovery.scope,
        )
        progress.save(
            title: show,
            episode: episode,
            position: 300,
            duration: 1800,
            finished: false,
            scope: discovery.scope,
        )
        let rows = home.rows.filter { $0.kind == .continueWatching }
        #expect(rows.count == 1)
        #expect(rows.first?.hub.title == "Continue Watching")
        #expect(rows.first?.items.count == 2)
        #expect(rows.first?.items.first?.playableItem?.type == .episode)
        #expect(home.rows.first?.id == "catalog:continue")
        #expect(!home.rows.contains { $0.id == "catalog:recent" })
    }

    @Test func `native hero supports movie and TV identities and respects the off setting`() {
        let movie = TMDBTitle.reference(id: 12, kind: .movie, title: "Movie")
        let show = TMDBTitle.reference(id: 12, kind: .tv, title: "Show")
        let home = CatalogHomeData(feeds: [.trendingMovies: [movie], .trendingTV: [show]])
        let slides = home.heroSlides(source: .discover)
        #expect(slides.count == 2)
        #expect(Set(slides.map(\.id)).count == 2)
        #expect(slides.map(\.media.type) == [.movie, .series])
        #expect(home.heroSlides(source: .off).isEmpty)
    }

    @Test func `native artwork model accepts TMDb artwork without a media server`() async throws {
        let title = try JSONDecoder().decode(
            TMDBTitle.self,
            from: Data(#"{"id":12,"media_type":"movie","title":"Movie","poster_path":"/poster.jpg"}"#.utf8),
        )
        let media = CatalogMediaAdapter.make(title: title, episode: nil, resume: nil)
        let model = MediaImageViewModel(artworkKind: .cardThumb, media: .playable(media))
        await model.load()
        guard case let .url(url) = model.resource else { Issue.record("Expected direct TMDb artwork"); return }
        #expect(url.host == "image.tmdb.org")
        #expect(CatalogMediaAdapter.artworkURL("file:///private/image.jpg") == nil)
        #expect(CatalogMediaAdapter.artworkURL("https://other.example/image.jpg") == nil)
    }
}
