import Foundation
import MediaPlayer

/// What the system Now Playing card shows for the current media.
struct NowPlayingItem {
    let title: String
    let subtitle: String?
    let artworkPath: String?
    let artworkService: (any MediaArtworkService)?
    let skipBackwardSeconds: Double
    let skipForwardSeconds: Double

    init(
        title: String,
        subtitle: String? = nil,
        artworkPath: String? = nil,
        artworkService: (any MediaArtworkService)? = nil,
        skipBackwardSeconds: Double,
        skipForwardSeconds: Double,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artworkPath = artworkPath
        self.artworkService = artworkService
        self.skipBackwardSeconds = skipBackwardSeconds
        self.skipForwardSeconds = skipForwardSeconds
    }

    init?(
        media: MediaItem?,
        artworkService: (any MediaArtworkService)?,
        skipBackwardSeconds: Int,
        skipForwardSeconds: Int,
    ) {
        guard let media else { return nil }
        let subtitle: String? = if case .episode = media.type {
            [media.grandparentTitle, media.tertiaryLabel]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ")
        } else {
            nil
        }
        self.init(
            title: media.title,
            subtitle: subtitle?.isEmpty == false ? subtitle : nil,
            artworkPath: CatalogMediaAdapter.selectionID(media) != nil && media.type == .episode
                ? (media.thumbPath ?? media.preferredThumbPath) : media.preferredThumbPath,
            artworkService: artworkService,
            skipBackwardSeconds: Double(skipBackwardSeconds),
            skipForwardSeconds: Double(skipForwardSeconds),
        )
    }

    /// Server artwork stays with its authenticated service. Catalog playback has no server service;
    /// only public TMDb image URLs may be fetched directly (never the signed playback URL).
    func artworkResources() async -> [ArtworkResource] {
        guard let artworkPath else { return [] }
        if let artworkService {
            return await (try? artworkService.artwork(path: artworkPath, width: 1024, height: nil)).map { [$0] } ?? []
        }
        guard let url = CatalogMediaAdapter.artworkURL(artworkPath) else { return [] }
        let parts = url.pathComponents
        guard parts.count >= 5, parts[1] == "t", parts[2] == "p" else { return [] }
        let original = TMDBImageService.imageURL(path: parts.dropFirst(4).joined(separator: "/"), size: .original)
        return (original == url ? [url] : [original, url].compactMap(\.self)).map(ArtworkResource.url)
    }

    /// Identity keys only: position, duration and rate come from the player.
    func identityInfo(artwork: MPMediaItemArtwork?, isLive: Bool) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if let subtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        return info
    }
}

enum NowPlayingPlayback {
    /// The rate the system extrapolates the elapsed time with.
    static func rate(isPlaying: Bool, isBuffering: Bool, requestedRate: Float) -> Double {
        guard isPlaying, !isBuffering else { return 0 }
        return Double(requestedRate > 0 ? requestedRate : 1)
    }

    /// Whether the published position drifted from what the system extrapolates, after a seek or a stall.
    static func hasDrifted(
        position: Double,
        publishedElapsed: Double,
        publishedRate: Double,
        secondsSincePublish: TimeInterval,
    ) -> Bool {
        let expected = publishedElapsed + publishedRate * secondsSincePublish
        return abs(position - expected) > 2
    }
}
