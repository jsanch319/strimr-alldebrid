import Foundation
import MediaPlayer
@testable import Strimr
import Testing

struct NowPlayingItemTests {
    private let server = ServerIdentity(provider: .jellyfin, id: "server-1")

    @Test func `an episode shows its series and number under the title`() throws {
        let media = MediaItem.make(
            id: "episode",
            server: server,
            title: "Pilot",
            type: .episode,
            seasonNumber: 1,
            episodeNumber: 3,
            seriesTitle: "Series",
        )

        let item = try #require(NowPlayingItem(
            media: media,
            artworkService: nil,
            skipBackwardSeconds: 10,
            skipForwardSeconds: 30,
        ))

        #expect(item.title == "Pilot")
        #expect(item.subtitle == "Series · \(String(localized: "media.labels.seasonEpisode \(1) \(3)"))")
        #expect(item.skipBackwardSeconds == 10)
        #expect(item.skipForwardSeconds == 30)
    }

    @Test func `an episode without series or number has no subtitle`() throws {
        let media = MediaItem.make(id: "episode", server: server, title: "Pilot", type: .episode)

        let item = try #require(NowPlayingItem(
            media: media,
            artworkService: nil,
            skipBackwardSeconds: 10,
            skipForwardSeconds: 10,
        ))

        #expect(item.subtitle == nil)
    }

    @Test func `a movie shows only its title`() throws {
        let media = MediaItem.make(id: "movie", server: server, title: "Movie", year: 2024)

        let item = try #require(NowPlayingItem(
            media: media,
            artworkService: nil,
            skipBackwardSeconds: 10,
            skipForwardSeconds: 10,
        ))

        #expect(item.title == "Movie")
        #expect(item.subtitle == nil)
    }

    @Test func `no media publishes nothing`() {
        #expect(NowPlayingItem(media: nil, artworkService: nil, skipBackwardSeconds: 10, skipForwardSeconds: 10) == nil)
    }

    @Test func `identity info leaves position and rate to the player`() {
        let item = NowPlayingItem(title: "Movie", subtitle: "Series", skipBackwardSeconds: 10, skipForwardSeconds: 10)

        let info = item.identityInfo(artwork: nil, isLive: true)

        #expect(info[MPMediaItemPropertyTitle] as? String == "Movie")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Series")
        #expect(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] == nil)
    }

    @Test func `catalog movies resolve high resolution TMDb artwork without a server`() async throws {
        let title = try JSONDecoder().decode(TMDBTitle.self, from: Data(
            #"{"id":42,"media_type":"movie","title":"Movie","poster_path":"/movie.jpg"}"#.utf8,
        ))
        let media = CatalogMediaAdapter.make(title: title, episode: nil, resume: 137)
        let item = try #require(NowPlayingItem(
            media: media, artworkService: nil, skipBackwardSeconds: 10, skipForwardSeconds: 30,
        ))
        let resources = await item.artworkResources()
        #expect(try resources == [
            .url(#require(URL(string: "https://image.tmdb.org/t/p/original/movie.jpg"))),
            .url(#require(URL(string: "https://image.tmdb.org/t/p/w500/movie.jpg"))),
        ])
        #expect(item.identityInfo(artwork: nil, isLive: false)[MPMediaItemPropertyTitle] as? String == "Movie")
    }

    @Test func `catalog episode artwork and identity change with the episode`() async throws {
        let title = try JSONDecoder().decode(TMDBTitle.self, from: Data(
            #"{"id":42,"media_type":"tv","name":"Series","poster_path":"/series.jpg"}"#.utf8,
        ))
        let episode = try JSONDecoder().decode(
            TMDBEpisode.self,
            from: Data(
                #"{"id":123,"name":"Second episode","season_number":2,"episode_number":3,"still_path":"/episode.jpg"}"#
                    .utf8,
            ),
        )
        let item = try #require(NowPlayingItem(
            media: CatalogMediaAdapter.make(title: title, episode: episode, resume: 101),
            artworkService: nil, skipBackwardSeconds: 10, skipForwardSeconds: 30,
        ))
        #expect(item.title == "Second episode")
        #expect(item.subtitle == "Series · \(String(localized: "media.labels.seasonEpisode \(2) \(3)"))")
        #expect(try await item.artworkResources()
            .first == .url(#require(URL(string: "https://image.tmdb.org/t/p/original/episode.jpg"))))
    }

    @Test func `missing artwork and non TMDb direct URLs are never fetched`() async {
        for path in [
            nil,
            "/server/thumb",
            "https://example.com/private?token=secret",
            "http://image.tmdb.org/t/p/w500/a.jpg",
        ] {
            let item = NowPlayingItem(
                title: "Movie",
                artworkPath: path,
                skipBackwardSeconds: 10,
                skipForwardSeconds: 30,
            )
            #expect(await item.artworkResources().isEmpty)
            #expect(item.identityInfo(artwork: nil, isLive: false)[MPMediaItemPropertyArtwork] == nil)
        }
    }

    @Test func `background audio remains enabled by default and honors an explicit disabled preference`() throws {
        #expect(PlaybackSettings().backgroundAudio)
        let disabled = try JSONDecoder().decode(PlaybackSettings.self, from: Data(#"{"backgroundAudio":false}"#.utf8))
        #expect(!disabled.backgroundAudio)
    }

    @Test func `late artwork identity refresh preserves a held background clock and discards old identity`() {
        let item = NowPlayingItem(title: "New movie", skipBackwardSeconds: 10, skipForwardSeconds: 30)
        let updated = item.updatingIdentity(in: [
            MPMediaItemPropertyTitle: "Old episode",
            MPMediaItemPropertyArtist: "Old series",
            MPMediaItemPropertyArtwork: "stale artwork",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 137.25,
            MPNowPlayingInfoPropertyPlaybackRate: 0.0,
            MPMediaItemPropertyPlaybackDuration: 3600.0,
        ], artwork: nil, isLive: false)
        #expect(updated[MPMediaItemPropertyTitle] as? String == "New movie")
        #expect(updated[MPMediaItemPropertyArtist] == nil)
        #expect(updated[MPMediaItemPropertyArtwork] == nil)
        #expect(updated[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 137.25)
        #expect(updated[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(updated[MPMediaItemPropertyPlaybackDuration] as? Double == 3600)
    }

    @Test func `the card only advances while playing and not buffering`() {
        #expect(NowPlayingPlayback.rate(isPlaying: true, isBuffering: false, requestedRate: 1.5) == 1.5)
        #expect(NowPlayingPlayback.rate(isPlaying: true, isBuffering: true, requestedRate: 1.5) == 0)
        #expect(NowPlayingPlayback.rate(isPlaying: false, isBuffering: false, requestedRate: 1.5) == 0)
        #expect(NowPlayingPlayback.rate(isPlaying: true, isBuffering: false, requestedRate: 0) == 1)
    }

    @Test func `a jump away from the extrapolated position is republished`() {
        #expect(!NowPlayingPlayback.hasDrifted(
            position: 105,
            publishedElapsed: 100,
            publishedRate: 1,
            secondsSincePublish: 5,
        ))
        #expect(NowPlayingPlayback.hasDrifted(
            position: 300,
            publishedElapsed: 100,
            publishedRate: 1,
            secondsSincePublish: 5,
        ))
        #expect(NowPlayingPlayback.hasDrifted(
            position: 110,
            publishedElapsed: 100,
            publishedRate: 0,
            secondsSincePublish: 5,
        ))
    }
}
