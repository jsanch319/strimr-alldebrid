@testable import Strimr
import Testing

@MainActor
struct MediaImageViewModelTests {
    private let server = ServerIdentity(provider: .jellyfin, id: "server-1")

    private func episode(seriesPoster: String? = "series-poster") -> MediaItem {
        .make(
            id: "episode-1",
            server: server,
            type: .episode,
            thumbPath: "episode-still",
            grandparentThumbPath: seriesPoster,
            grandparentArtPath: "series-backdrop",
            parentThumbPath: "season-poster",
        )
    }

    private func viewModel(_ item: MediaItem, kind: MediaImageViewModel.ArtworkKind) -> MediaImageViewModel {
        MediaImageViewModel(services: .fake(), artworkKind: kind, media: .playable(item))
    }

    @Test func `replacing artwork changes image identity while resume checkpoints retain it`() {
        let original = MediaItem.make(id: "movie", server: server, viewOffset: 100, artPath: "first")
        let checkpoint = MediaItem.make(id: "movie", server: server, viewOffset: 150, artPath: "first")
        let replaced = MediaItem.make(id: "movie", server: server, viewOffset: 150, artPath: "second")
        #expect(viewModel(original, kind: .cardArt).artworkIdentity == viewModel(checkpoint, kind: .cardArt)
            .artworkIdentity)
        #expect(viewModel(original, kind: .cardArt).artworkIdentity != viewModel(replaced, kind: .cardArt)
            .artworkIdentity)
    }

    @Test func `spoiler protection hides the episode image of a landscape card`() {
        let model = viewModel(episode(), kind: .cardArt)

        #expect(model.hidesSpoiler(at: .thumbnails, landscape: .episode, portrait: .series))
        #expect(!model.hidesSpoiler(at: .thumbnails, landscape: .series, portrait: .series))
    }

    @Test func `spoiler protection keeps the series poster of a portrait card`() {
        let model = viewModel(episode(), kind: .cardThumb)

        #expect(!model.hidesSpoiler(at: .thumbnails, landscape: .episode, portrait: .series))
        #expect(!model.hidesSpoiler(at: .thumbnails, landscape: .episode, portrait: .season))
    }

    @Test func `spoiler protection hides a portrait card that falls back to the episode image`() {
        let model = viewModel(episode(seriesPoster: nil), kind: .thumb)
        let item = MediaItem.make(id: "e", server: server, type: .episode, thumbPath: "episode-still")
        let fallback = viewModel(item, kind: .thumb)

        #expect(!model.hidesSpoiler(at: .thumbnails, landscape: .episode, portrait: .series))
        #expect(fallback.hidesSpoiler(at: .thumbnails, landscape: .episode, portrait: .series))
    }

    @Test func `spoiler protection hides an episode backdrop shown for lack of a still`() {
        let item = MediaItem.make(id: "e", server: server, type: .episode, artPath: "episode-backdrop")

        #expect(viewModel(item, kind: .cardArt).hidesSpoiler(at: .thumbnails, landscape: .episode, portrait: .series))
    }

    @Test func `season poster preference applies to episode and season portrait cards only`() {
        let season = MediaItem.make(id: "season-1", server: server, type: .season)
        let movie = MediaItem.make(id: "movie-1", server: server, type: .movie)

        #expect(viewModel(episode(), kind: .cardThumb).followsSeriesArtworkPreference(
            landscape: .episode,
            portrait: .season,
        ))
        #expect(viewModel(season, kind: .cardThumb).followsSeriesArtworkPreference(
            landscape: .episode,
            portrait: .season,
        ))
        #expect(!viewModel(movie, kind: .cardThumb).followsSeriesArtworkPreference(
            landscape: .series,
            portrait: .season,
        ))
        #expect(!viewModel(season, kind: .cardArt).followsSeriesArtworkPreference(
            landscape: .series,
            portrait: .season,
        ))
        #expect(!viewModel(episode(), kind: .thumb).followsSeriesArtworkPreference(
            landscape: .series,
            portrait: .season,
        ))
    }
}
