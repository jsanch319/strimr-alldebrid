import SwiftUI

/// Detail-only source/layout policy. Home continues using its existing landscape backdrop renderer.
@MainActor
struct CatalogDetailArtworkSource: Hashable {
    let candidates: [URL]
    let usesPoster: Bool

    init(title: TMDBTitle) {
        let poster = TMDBImageService.imageURL(path: title.poster_path, size: .original)
        usesPoster = poster != nil
        candidates = [
            poster,
            TMDBImageService.imageURL(path: title.poster_path, size: .w780),
            TMDBImageService.imageURL(path: title.backdrop_path, size: .w1280),
        ].compactMap(\.self)
    }

    func imageHeight(width: CGFloat, viewport: CGFloat) -> CGFloat {
        guard !candidates.isEmpty else { return 0 }
        return min(width * (usesPoster ? 1.5 : 9 / 16), viewport * 0.88)
    }

    func contentInset(width: CGFloat, viewport: CGFloat) -> CGFloat {
        guard !candidates.isEmpty else { return 24 }
        return imageHeight(width: width, viewport: viewport) * (usesPoster ? 0.62 : 0.72)
    }
}

#if os(iOS)
    /// Sharp fitted foreground and a tinted, softly textured full-screen background from the same title.
    /// Only the decorative blurred layer fills/crops; the foreground image always preserves its complete composition.
    struct CatalogDetailArtwork: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let source: CatalogDetailArtworkSource
        @State private var model = CatalogHomeBackdropModel(loader: CatalogDetailArtwork.load)

        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    Color.background
                    ForEach(model.layers) { layer in
                        ZStack(alignment: .top) {
                            MediaBackdropGradient(colors: layer.colors)
                                .overlay(Color.black.opacity(0.40))
                            layer.image.resizable().scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped().blur(radius: 32).opacity(0.18)
                            layer.image.resizable().scaledToFit()
                                .frame(
                                    width: proxy.size.width,
                                    height: source.imageHeight(width: proxy.size.width, viewport: proxy.size.height),
                                    alignment: .top,
                                )
                                .mask(LinearGradient(stops: [
                                    .init(color: .white, location: 0),
                                    .init(color: .white, location: 0.53),
                                    .init(color: .white.opacity(0.88), location: 0.68),
                                    .init(color: .white.opacity(0.4), location: 0.86),
                                    .init(color: .clear, location: 1),
                                ], startPoint: .top, endPoint: .bottom))
                            // Status/back controls and lower text have their own gentle readability scrims.
                            LinearGradient(stops: [
                                .init(color: .black.opacity(0.48), location: 0),
                                .init(color: .clear, location: 0.22),
                                .init(color: .black.opacity(0.05), location: 0.4),
                                .init(color: .black.opacity(0.3), location: 0.66),
                                .init(color: .black.opacity(0.38), location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: model.current?.id)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay(alignment: .bottomLeading) {
                #if DEBUG && targetEnvironment(simulator)
                    if CatalogVisualFixtures.isEnabled {
                        VStack(spacing: 0) {
                            Text("Details artwork state")
                                .accessibilityIdentifier("visual.backdrop")
                                .accessibilityValue(model.current?.url.absoluteString ?? "none")
                            Text("Detail image source")
                                .accessibilityIdentifier("catalog.detail.artwork-source")
                                .accessibilityValue(model.current?.url.absoluteString ?? "none")
                        }
                        .font(.system(size: 1)).foregroundStyle(.clear)
                        .accessibilityElement(children: .contain)
                        .accessibilityHidden(false)
                    }
                #endif
            }
            .task(id: source) {
                for url in source.candidates {
                    guard !Task.isCancelled else { return }
                    await model.update(url: url, reduceMotion: reduceMotion)
                    guard !Task.isCancelled else { return }
                    if model.current != nil {
                        return
                    }
                }
                if source.candidates.isEmpty {
                    await model.update(url: nil, reduceMotion: reduceMotion)
                }
            }
        }

        private static func load(_ url: URL) async -> CatalogHomeBackdropModel.Layer? {
            let resource = ArtworkResource.url(url)
            guard let image = await ArtworkResourceView.image(for: resource) else { return nil }
            let sampled = await ArtworkProgressPaletteCache.shared.colors(for: resource).map(\.color)
            let corners: [Color] = if sampled.count >= 2 {
                [sampled[0], sampled[1], sampled.last!, sampled[0]]
            } else {
                []
            }
            return CatalogHomeBackdropModel.Layer(url: url, image: image, colors: corners)
        }
    }
#endif
