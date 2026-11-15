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
