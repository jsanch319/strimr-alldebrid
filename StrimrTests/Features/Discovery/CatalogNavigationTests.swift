import Foundation
@testable import Strimr
import SwiftUI
import Testing

@MainActor
struct CatalogNavigationTests {
    @Test func `six server-free destinations fit the native compact bar using More`() {
        #expect(CatalogTab.destinations == [.home, .search, .movies, .tvShows, .myList, .settings])
        let layout = CatalogTabLayout(isCompact: true)
        #expect(layout.bar == [.home, .search, .movies, .tvShows, .more])
        #expect(layout.overflow == [.myList, .settings])
        #expect(Set(layout.bar.filter { $0 != .more } + layout.overflow) == Set(CatalogTab.destinations))
        #expect(layout.bar.count == 5)
    }

    @Test func `movie and TV destinations request their own real TMDb catalogs`() {
        #expect(CatalogTab.movies.feeds == [.trendingMovies, .popularMovies, .upcoming, .topMovies])
        #expect(CatalogTab.tvShows.feeds == [.trendingTV, .popularTV, .topTV])
        #expect(CatalogTab.movies.feeds.allSatisfy { $0.kind == .movie })
        #expect(CatalogTab.tvShows.feeds.allSatisfy { $0.kind == .tv })
    }

    @Test func `episode Home backdrop is its matching series and never an unrelated poster`() throws {
        let title = try JSONDecoder().decode(
            TMDBTitle.self,
            from: Data(
                #"{"id":12,"media_type":"tv","name":"Series","poster_path":"/poster.jpg","backdrop_path":"/series.jpg"}"#
                    .utf8,
            ),
        )
        let episode = try JSONDecoder().decode(
            TMDBEpisode.self,
            from: Data(#"{"id":1,"season_number":2,"episode_number":3,"name":"Episode","still_path":"/episode.jpg"}"#
                .utf8),
        )
        let media = CatalogMediaAdapter.make(title: title, episode: episode, resume: 125)
        #expect(CatalogHomeBackdropModel.artworkURL(for: media)?.lastPathComponent == "series.jpg")
        let missingBackdrop = TMDBTitle.reference(id: 99, kind: .movie, title: "No backdrop")
        #expect(CatalogHomeBackdropModel.artworkURL(for: CatalogMediaAdapter.make(
            title: missingBackdrop,
            episode: nil,
            resume: nil,
        )) == nil)
        #expect(CatalogHomeBackdropModel
            .artworkURL(for: CatalogMediaAdapter.raw(id: "file:1", filename: "Movie.mkv")) == nil)
        #expect(CatalogMediaAdapter.artworkURL("https://unrelated.example/image.jpg") == nil)
    }

    @Test func `backdrop retains the cached current image and Reduce Motion replaces without layers`() async throws {
        let first = try #require(URL(string: "https://image.tmdb.org/t/p/w1280/first.jpg"))
        let second = try #require(URL(string: "https://image.tmdb.org/t/p/w1280/second.jpg"))
        var loads = 0
        let model = CatalogHomeBackdropModel { url in
            loads += 1
            return .init(url: url, image: Image(systemName: "film"))
        }
        await model.update(url: first, reduceMotion: true)
        await model.update(url: first, reduceMotion: true)
        #expect(loads == 1)
        await model.update(url: second, reduceMotion: true)
        #expect(model.current?.url == second)
        #expect(model.previous == nil)
        #expect(model.layers.count == 1)
        await model.update(url: nil, reduceMotion: true)
        #expect(model.layers.isEmpty)
    }

    @Test func `a late obsolete backdrop cannot replace the latest selection`() async throws {
        let first = try #require(URL(string: "https://image.tmdb.org/t/p/w1280/first.jpg"))
        let second = try #require(URL(string: "https://image.tmdb.org/t/p/w1280/second.jpg"))
        var model: CatalogHomeBackdropModel!
        model = CatalogHomeBackdropModel { url in
            if url == first {
                await model.update(url: second, reduceMotion: true)
            }
            return .init(url: url, image: Image(systemName: "film"))
        }
        await model.update(url: first, reduceMotion: true)
        #expect(model.current?.url == second)
    }

    @Test func `failed backdrop loads clear previous title artwork rather than substituting an image`() async throws {
        let first = try #require(URL(string: "https://image.tmdb.org/t/p/w1280/first.jpg"))
        let missing = try #require(URL(string: "https://image.tmdb.org/t/p/w1280/missing.jpg"))
        let model = CatalogHomeBackdropModel { url in
            url == missing ? nil : .init(url: url, image: Image(systemName: "film"))
        }
        await model.update(url: first, reduceMotion: true)
        await model.update(url: missing, reduceMotion: true)
        #expect(model.layers.isEmpty)
    }
}
