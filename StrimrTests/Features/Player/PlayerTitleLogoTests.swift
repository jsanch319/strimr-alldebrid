import CoreGraphics
import Foundation
@testable import Strimr
import Testing

@MainActor
struct PlayerTitleLogoTests {
    @Test func `catalog episodes use the show identity and display season and episode`() throws {
        let show = TMDBTitle.reference(id: 42, kind: .tv, title: "Series")
        let episode = try JSONDecoder().decode(TMDBEpisode.self, from: Data(
            #"{"id":999,"name":"Pilot","season_number":2,"episode_number":3}"#.utf8,
        ))
        let identity = PlayerTitleLogoIdentity(media: CatalogMediaAdapter.make(
            title: show,
            episode: episode,
            resume: 90,
        ))
        #expect(identity.tmdbID == 42)
        #expect(identity.kind == .tv)
        #expect(identity.title == "Series")
        #expect(identity.episode?.contains("Pilot") == true)
        #expect(identity.episode?.contains(String(localized: "media.labels.seasonEpisode \(2) \(3)")) == true)
        let movie = PlayerTitleLogoIdentity(media: CatalogMediaAdapter.make(
            title: .reference(id: 42, kind: .movie, title: "Film"), episode: nil, resume: nil,
        ))
        #expect(movie.kind == .movie)
        #expect(movie != identity)
        #expect(movie.episode == nil)
    }

    @Test func `a server episode ID is never mistaken for a show ID`() {
        let server = ServerIdentity(provider: .jellyfin, id: "test")
        let media = MediaItem.make(
            id: "episode",
            server: server,
            title: "Pilot",
            type: .episode,
            externalIDs: ExternalIDs(tmdb: "999"),
            seasonNumber: 1,
            episodeNumber: 1,
            seriesTitle: "Series",
        )
        let identity = PlayerTitleLogoIdentity(media: media)
        #expect(identity.tmdbID == nil)
        #expect(identity.title == "Series")
    }

    @Test func `opaque and empty bitmaps are rejected while transparent artwork is accepted`() async throws {
        func image(alpha: UInt8, transparentEdge: Bool) throws -> CGImage {
            var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                pixels[index] = alpha; pixels[index + 1] = alpha; pixels[index + 2] = alpha
                pixels[index + 3] = transparentEdge && index < 8 * 4 ? 0 : alpha
            }
            let data = Data(pixels) as CFData
            let provider = try #require(CGDataProvider(data: data))
            return try #require(CGImage(
                width: 8,
                height: 8,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 8 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent,
            ))
        }
        let opaque = try image(alpha: 255, transparentEdge: false)
        let empty = try image(alpha: 0, transparentEdge: false)
        let transparent = try image(alpha: 255, transparentEdge: true)
        #expect(await !PlayerTitleLogoPolicy.hasTransparency(opaque))
        #expect(await !PlayerTitleLogoPolicy.hasTransparency(empty))
        #expect(await PlayerTitleLogoPolicy.hasTransparency(transparent))
    }

    @Test func `fallback text retains artwork channel ordering while ensuring contrast`() {
        for swatch in [
            ProgressArtworkColor(red: 0.12, green: 0.03, blue: 0.01),
            ProgressArtworkColor(red: 0.1, green: 0.3, blue: 0.6),
        ] {
            let readable = PlayerTitleLogoPolicy.readableTextColor(swatch)
            #expect(readable.luminance >= 0.35)
            #expect((readable.red > readable.blue) == (swatch.red > swatch.blue))
        }
    }
}
