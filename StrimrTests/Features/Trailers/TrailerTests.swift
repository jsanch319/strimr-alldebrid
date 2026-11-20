import AVFoundation
import Foundation
@testable import Strimr
import Testing

@MainActor
struct TrailerTests {
    @Test func `movie TV and season trailer discovery uses official localized metadata and caches it`() async throws {
        for kind in [TMDBTitle.Kind.movie, .tv] {
            let stub = HTTPStub { _ in
                .json(
                    #"{"results":[{"id":"fr","name":"Official French","site":"YouTube","key":"abcdefghijk","type":"Trailer","official":true,"iso_639_1":"fr","size":720},{"id":"en","name":"Official English","site":"YouTube","key":"12345678901","type":"Trailer","official":true,"iso_639_1":"en","size":1080},{"id":"fan","name":"Fan upload","site":"YouTube","key":"abcdefghijk","type":"Trailer","official":false},{"id":"teaser","name":"Teaser","site":"YouTube","key":"abcdefghijk","type":"Teaser","official":true}]}"#,
                )
            }
            let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
            let result = try await client.trailers(id: 42, kind: kind, language: "fr-FR")
            #expect(result.map(\.id) == ["fr", "en"])
            #expect(result.first?.source == .youTube("abcdefghijk"))
            #expect(try await client.trailers(id: 42, kind: kind, language: "fr-FR") == result)
            #expect(stub.requests.count == 1)
            let request = try #require(stub.requests.first)
            #expect(request.url?.path == "/3/\(kind.rawValue)/42/videos")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.url?.absoluteString.contains("test-token") == false)
            #expect(try await client.trailers(id: 0, kind: kind).isEmpty)
        }
    }

    @Test func `concurrent hero and detail lookups share one trailer request`() async throws {
        let stub = HTTPStub { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .json(#"{"results":[]}"#)
        }
        let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
        async let hero = client.trailers(id: 693_134, kind: .movie)
        async let details = client.trailers(id: 693_134, kind: .movie)
        let results = try await [hero, details]
        #expect(results.count == 2)
        for result in results {
            #expect(result.isEmpty)
        }
        #expect(stub.requests.count == 1)
    }

    @Test func `missing season video endpoint falls back without changing the title scope`() async throws {
        let stub = HTTPStub { request in
            if request.url?.path.contains("/season/0/") == true {
                return .init(statusCode: 404)
            }
            return .json(#"{"results":[]}"#)
        }
        let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
        #expect(try await client.trailers(id: 95396, kind: .tv, season: 0).isEmpty)
        #expect(stub.requests.map { $0.url?.path } == ["/3/tv/95396/season/0/videos", "/3/tv/95396/videos"])
    }

    @Test func `a TV season trailer is preferred and unavailable seasons fall back to series`() async throws {
        for available in [true, false] {
            let stub = HTTPStub { request in
                if request.url?.path.contains("/season/2/") == true, !available {
                    return .json(#"{"results":[]}"#)
                }
                return .json(
                    #"{"results":[{"id":"one","name":"Official","site":"Vimeo","key":"123456789","type":"Trailer","official":true}]}"#,
                )
            }
            let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
            let result = try await client.trailers(id: 12, kind: .tv, season: 2)
            #expect(result.first?.source == .vimeo("123456789"))
            #expect(stub.requests.first?.url?.path == "/3/tv/12/season/2/videos")
            #expect(stub.requests.count == (available ? 1 : 2))
            if !available {
                #expect(stub.requests.last?.url?.path == "/3/tv/12/videos")
            }
        }
    }

    @Test func `missing trailers unsupported hosts and invalid embed IDs remain unavailable`() async throws {
        let stub = HTTPStub { _ in
            .json(
                #"{"results":[{"id":"bad","name":"Bad","site":"YouTube","key":"<script>","type":"Trailer","official":true},{"id":"unknown","name":"Unknown","site":"Other","key":"https://host/video.mp4","type":"Trailer","official":true}]}"#,
            )
        }
        let client = TMDBClient(session: stub.session, tokenProvider: { "test-token" })
        #expect(try await client.trailers(id: 99, kind: .movie).isEmpty)
        let origin = try #require(URL(string: "https://app.example"))
        #expect(TrailerEmbedConfiguration.html(source: .youTube("<script>"), origin: origin) == nil)
    }

    @Test func `YouTube embeds identify the native app require manual play and do not loop or suppress controls`(
    ) throws {
        let origin = try #require(TrailerEmbedConfiguration.origin(bundleID: "app.strimr.ios"))
        let html = try #require(TrailerEmbedConfiguration.html(source: .youTube("abcdefghijk"), origin: origin))
        #expect(html.contains("youtube.com/iframe_api"))
        #expect(html.contains("youtube-nocookie.com"))
        #expect(html.contains("autoplay:0"))
        #expect(html.contains("controls:1"))
        #expect(html.contains("loop:0"))
        #expect(html.contains("https://app.strimr.ios"))
        #expect(!TrailerSource.youTube("abcdefghijk").supportsInlinePreview)
        #expect(TrailerEmbedConfiguration.origin(bundleID: "bad'\"id") == nil)
    }

    @Test func `automatic preview policy stops for swipes background offscreen accessibility power and cellular`() {
        func allowed(
            visible: Bool = true,
            active: Bool = true,
            settled: Bool = true,
            reduceMotion: Bool = false,
            lowPower: Bool = false,
            connected: Bool = true,
            expensive: Bool = false,
            constrained: Bool = false,
            cellular: Bool = false,
            playing: Bool = false,
        ) -> Bool {
            TrailerPreviewPolicy.allowsAutoplay(
                enabled: true,
                visible: visible,
                active: active,
                settled: settled,
                reduceMotion: reduceMotion,
                lowPower: lowPower,
                connected: connected,
                expensive: expensive,
                constrained: constrained,
                allowsCellular: cellular,
                anotherPlayerActive: playing,
            )
        }
        #expect(allowed())
        #expect(!allowed(visible: false)); #expect(!allowed(active: false)); #expect(!allowed(settled: false))
        #expect(!allowed(reduceMotion: true)); #expect(!allowed(lowPower: true)); #expect(!allowed(connected: false))
        #expect(!allowed(expensive: true)); #expect(allowed(expensive: true, cellular: true))
        #expect(!allowed(constrained: true, cellular: true)); #expect(!allowed(playing: true))
    }

    @Test func `trailer ownership stops previews before manual trailers or feature playback and rejects overlaps`() {
        let coordinator = TrailerPlaybackCoordinator()
        let preview = UUID(), manual = UUID(), feature = UUID()
        var stops = 0
        #expect(coordinator.claim(preview, manual: false) { stops += 1 })
        #expect(coordinator.claim(manual, manual: true) { stops += 1 })
        #expect(stops == 1)
        #expect(!coordinator.claim(preview, manual: false, stop: {}))
        coordinator.beginFeature(feature)
        #expect(stops == 2)
        #expect(!coordinator.claim(manual, manual: true, stop: {}))
        coordinator.endFeature(UUID())
        #expect(coordinator.featurePlaybackActive)
        coordinator.endFeature(feature)
        #expect(coordinator.claim(preview, manual: false, stop: {}))
        coordinator.release(manual)
        coordinator.release(preview)
        #expect(!coordinator.manualTrailerActive)
    }

    @Test func `native previews start muted mute controls change the player and stop clears readiness`() {
        let preview = DirectTrailerPreview()
        #expect(preview.muted && preview.player.isMuted)
        preview.toggleMute()
        #expect(!preview.muted && !preview.player.isMuted)
        preview.toggleMute()
        #expect(preview.muted && preview.player.isMuted)
        preview.ready = true
        preview.stop()
        #expect(!preview.active && !preview.ready)
        #expect(preview.player.currentItem == nil)
        #expect(preview.player.rate == 0)
    }

    @Test func `direct streams need an explicit provider contract and never reuse extracted YouTube URLs`() throws {
        let extractedURL = try #require(URL(string: "https://video.googlevideo.com/movie.mp4"))
        let insecureURL = try #require(URL(string: "http://provider.example/trailer.mp4"))
        let authorizedURL = try #require(URL(string: "https://provider.example/trailer.m3u8"))
        #expect(AuthorizedTrailerStream(catalogID: "movie:1", url: extractedURL, provider: "Unknown") == nil)
        #expect(AuthorizedTrailerStream(catalogID: "movie:1", url: insecureURL, provider: "Provider") == nil)
        let stream = try #require(AuthorizedTrailerStream(
            catalogID: "movie:1", url: authorizedURL, provider: "Authorized provider",
        ))
        #expect(!stream.permitsAdFreeLooping)
        #expect(TrailerSource.direct(stream).supportsInlinePreview)
        let defaults = PlaybackSettings()
        #expect(defaults.automaticTrailerPreviews)
        #expect(!defaults.trailerPreviewsOnCellular)
        let old = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        #expect(old.automaticTrailerPreviews && !old.trailerPreviewsOnCellular)
    }
}
