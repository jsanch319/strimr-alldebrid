import CoreGraphics
import SwiftUI

/// Episode TMDb IDs from a server can identify an episode, not the show. Only catalog GUIDs
/// explicitly carrying the series identity are safe to use for a series-logo request.
struct PlayerTitleLogoIdentity: Hashable {
    let key: String
    let title: String
    let episode: String?
    let logoPath: String?
    let posterPath: String?
    let tmdbID: Int?
    let kind: TMDBTitle.Kind?

    init(media: MediaItem) {
        key = "\(media.serverIdentifier)|\(media.id)|\(media.guid)"
        title = media.primaryLabel
        episode = media.type == .episode ? media.episodeTitleLabel : nil
        logoPath = media.preferredLogoPath
        posterPath = media.preferredThumbPath
        let catalog = media.guid.replacingOccurrences(of: "tmdb://", with: "").split(separator: ":")
        if media.guid.hasPrefix("tmdb://"), catalog.count == 2,
           let type = TMDBTitle.Kind(rawValue: String(catalog[0])), let id = Int(catalog[1]), id > 0
        {
            tmdbID = id; kind = type
        } else if media.type == .movie || media.type == .series,
                  let id = media.externalIDs.tmdb.flatMap(Int.init), id > 0
        {
            tmdbID = id; kind = media.type == .movie ? .movie : .tv
        } else {
            tmdbID = nil; kind = nil
        }
    }
}

nonisolated enum PlayerTitleLogoPolicy {
    /// A PNG extension alone does not establish that a logo actually has a transparent background.
    @concurrent static func hasTransparency(_ image: CGImage) async -> Bool {
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        return alpha.contains { $0 < 250 } && alpha.contains { $0 > 0 }
    }

    /// Only the fallback text is styled. Branded image pixels are never tinted or color-normalized.
    static func readableTextColor(_ color: ProgressArtworkColor) -> ProgressArtworkColor {
        var result = color
        while result.luminance < 0.35 {
            result = ProgressArtworkColor(
                red: result.red + (1 - result.red) * 0.1,
                green: result.green + (1 - result.green) * 0.1,
                blue: result.blue + (1 - result.blue) * 0.1,
            )
        }
        return result
    }
}

#if os(iOS)
    struct PlayerTitleLogoView: View {
        @Environment(ServerRegistry.self) private var registry
        @Environment(MediaServices.self) private var scopedServices: MediaServices?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let media: MediaItem
        let compact: Bool
        @State private var loaded: (identity: PlayerTitleLogoIdentity, image: Image)?
        @State private var palette: (identity: PlayerTitleLogoIdentity, colors: [Color])?

        private var identity: PlayerTitleLogoIdentity {
            PlayerTitleLogoIdentity(media: media)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                if let loaded, loaded.identity == identity {
                    loaded.image.resizable().renderingMode(.original).scaledToFit()
                        .frame(maxWidth: 260, maxHeight: compact ? 40 : 68, alignment: .leading)
                        .accessibilityLabel(identity.title)
                } else {
                    Text(identity.title).font(.system(size: compact ? 22 : 28, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: textColors, startPoint: .leading, endPoint: .trailing))
                        .lineLimit(2).minimumScaleFactor(0.7)
                }
                if let episode = identity.episode {
                    Text(episode).font(.caption).foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.8)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .frame(maxWidth: 280, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("player.title-logo")
            .task(id: identity) { await load(identity) }
        }

        private var textColors: [Color] {
            guard let palette, palette.identity == identity, !palette.colors.isEmpty else { return [.white, .white] }
            return palette.colors.count == 1 ? palette.colors + palette.colors : palette.colors
        }

        private func load(_ requested: PlayerTitleLogoIdentity) async {
            let services = registry.services(for: .playable(media), scoped: scopedServices)
            async let colors: Void = loadPalette(requested, services: services)
            if let id = requested.tmdbID, let kind = requested.kind,
               let logos = try? await TMDBClient.shared.titleLogos(id: id, kind: kind)
            {
                for logo in logos {
                    guard !Task.isCancelled else { return }
                    if let url = TMDBImageService.imageURL(path: logo.file_path, size: .original),
                       let image = await ArtworkResourceView.transparentImage(for: .url(url)), !Task.isCancelled
                    {
                        setImage(image, identity: requested)
                        _ = await colors
                        return
                    }
                }
            }
            // Preserve authenticated server artwork for media-server playback too.
            if let path = requested.logoPath, let services,
               let resource = try? await services.artwork.artwork(path: path, width: 1040, height: nil),
               let image = await ArtworkResourceView.transparentImage(for: resource), !Task.isCancelled
            {
                setImage(image, identity: requested)
            }
            _ = await colors
        }

        private func setImage(_ image: Image, identity: PlayerTitleLogoIdentity) {
            withAnimation(reduceMotion ? nil : Motion.crossfade) { loaded = (identity, image) }
        }

        private func loadPalette(_ requested: PlayerTitleLogoIdentity, services: MediaServices?) async {
            let resource: ArtworkResource? = if let url = CatalogMediaAdapter.artworkURL(requested.posterPath) {
                .url(url)
            } else if let path = requested.posterPath, let services {
                try? await services.artwork.artwork(path: path, width: 300, height: nil)
            } else {
                nil
            }
            guard let resource else { return }
            let colors = await ArtworkProgressPaletteCache.shared.colors(for: resource)
                .map { PlayerTitleLogoPolicy.readableTextColor($0).color }
            guard !Task.isCancelled else { return }
            palette = (requested, colors)
        }
    }
#endif
