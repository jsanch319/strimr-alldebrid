#if !os(tvOS)
    import Observation
    import SwiftUI

    /// Uses the original decoded artwork cache and corner sampler. No random or poster fallback artwork.
    @MainActor
    @Observable
    final class CatalogHomeBackdropModel {
        struct Layer: Identifiable {
            let url: URL
            let image: Image
            var colors: [Color] = []
            var id: URL {
                url
            }
        }

        private(set) var current: Layer?
        private(set) var previous: Layer?
        @ObservationIgnored private var generation = 0
        @ObservationIgnored private let loader: @MainActor (URL) async -> Layer?
        init(loader: @escaping @MainActor (URL) async -> Layer? = CatalogHomeBackdropModel.loadArtwork) {
            self.loader = loader
        }

        var layers: [Layer] {
            [previous, current].compactMap(\.self)
        }

        static func artworkURL(for media: MediaItem?) -> URL? {
            guard let media, media.guid.hasPrefix("tmdb://") else { return nil }
            // Episode stills can reveal spoilers: Home always uses the corresponding series backdrop.
            let path = media.type == .episode ? media.grandparentArtPath : media.artPath
            return CatalogMediaAdapter.artworkURL(path)
        }

        func update(url: URL?, reduceMotion: Bool) async {
            generation += 1
            let request = generation
            guard let url else { current = nil; previous = nil; return }
            guard current?.url != url else { previous = nil; return }
            let loaded = await loader(url)
            guard !Task.isCancelled, request == generation else { return }
            guard let loaded else {
                // A missing title backdrop must not leave another title's image on screen.
                current = nil; previous = nil; return
            }
            previous = reduceMotion ? nil : current
            current = loaded
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, request == generation else { return }
            previous = nil
        }

        private static func loadArtwork(_ url: URL) async -> Layer? {
            let resource = ArtworkResource.url(url)
            guard let image = await ArtworkResourceView.image(for: resource) else { return nil }
            let colors = await (try? ImageCornerColorSampler.colors(from: resource)) ?? []
            return Layer(url: url, image: image, colors: colors)
        }
    }

    /// iOS adapts tvOS's layered, preloaded backdrop treatment behind the existing vertical Home.
    struct CatalogHomeBackdrop: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let media: MediaItem?
        @State private var model = CatalogHomeBackdropModel()
        private var url: URL? {
            CatalogHomeBackdropModel.artworkURL(for: media)
        }

        var body: some View {
            GeometryReader { proxy in
                ZStack {
                    Color.background
                    ForEach(model.layers) { layer in
                        ZStack(alignment: .topTrailing) {
                            MediaBackdropGradient(colors: layer.colors)
                            layer.image.resizable().scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped().blur(radius: 40).opacity(0.25)
                            layer.image.resizable().scaledToFill()
                                .frame(
                                    width: proxy.size.width,
                                    height: proxy.size.height * 0.82,
                                    alignment: .topTrailing,
                                )
                                .clipped()
                                .mask(LinearGradient(stops: [
                                    .init(color: .white.opacity(0.85), location: 0),
                                    .init(color: .white.opacity(0.65), location: 0.4),
                                    .init(color: .clear, location: 1),
                                ], startPoint: .top, endPoint: .bottom))
                            LinearGradient(
                                colors: [.background.opacity(0.65), .background.opacity(0.2)],
                                startPoint: .leading,
                                endPoint: .trailing,
                            )
                            LinearGradient(
                                colors: [.clear, .background.opacity(0.9)],
                                startPoint: .top,
                                endPoint: .bottom,
                            )
                        }
                        .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: model.current?.id)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: url) { await model.update(url: url, reduceMotion: reduceMotion) }
        }
    }
#endif
