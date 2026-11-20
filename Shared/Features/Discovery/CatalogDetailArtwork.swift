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

/// A title-derived solid surface. Keep the artwork hue while bounding luminance for white/secondary text.
nonisolated enum CatalogDetailSurfacePalette {
    static let fallback = ProgressArtworkColor(red: 0.18, green: 0.20, blue: 0.23)

    static func surface(from samples: [ProgressArtworkColor]) -> ProgressArtworkColor {
        guard let sample = samples.first else { return fallback }
        // Avoid a black page for nearly black artwork without introducing a different accent hue.
        let lifted = ProgressArtworkColor(
            red: max(0.10, sample.red),
            green: max(0.10, sample.green),
            blue: max(0.10, sample.blue),
        )
        var low = 0.0, high = 1.0
        for _ in 0 ..< 24 {
            let scale = (low + high) / 2
            let color = ProgressArtworkColor(
                red: lifted.red * scale,
                green: lifted.green * scale,
                blue: lifted.blue * scale,
            )
            if color.luminance > 0.055 {
                high = scale
            } else {
                low = scale
            }
        }
        return ProgressArtworkColor(red: lifted.red * low, green: lifted.green * low, blue: lifted.blue * low)
    }

    /// End in the gap after the actual tracking controls, never in metadata or a fixed viewport fraction.
    static func transitionEnd(trackingBottom: CGFloat) -> CGFloat {
        trackingBottom.isFinite ? max(0, trackingBottom + 11) : 0
    }
}

#if os(iOS)
    /// One artwork-to-solid fade, in scroll-content coordinates. Nothing is drawn below the tracking boundary.
    struct CatalogDetailArtwork: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let source: CatalogDetailArtworkSource
        let transitionEnd: CGFloat
        let model: CatalogHomeBackdropModel

        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    (model.current?.colors.first ?? CatalogDetailSurfacePalette.fallback.color)
                    ForEach(model.layers) { layer in
                        layer.image.resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: max(1, transitionEnd), alignment: .top)
                            .clipped()
                            .mask(LinearGradient(stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: 0.28),
                                .init(color: .white.opacity(0.65), location: 0.48),
                                .init(color: .white.opacity(0.16), location: 0.75),
                                .init(color: .clear, location: 1),
                            ], startPoint: .top, endPoint: .bottom))
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: model.current?.id)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                #if DEBUG && targetEnvironment(simulator)
                    if CatalogVisualFixtures.isEnabled {
                        VStack(spacing: 0) {
                            Text("Details artwork state")
                                .accessibilityIdentifier("visual.backdrop")
                                .accessibilityValue(model.current?.url.absoluteString ?? "none")
                            Text("Detail image source")
                                .accessibilityIdentifier("catalog.detail.artwork-source")
                                .accessibilityValue(model.current?.url.absoluteString ?? "none")
                            Text("Solid surface boundary")
                                .accessibilityIdentifier("catalog.detail.surface-boundary")
                                .accessibilityValue(String(Double(transitionEnd)))
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

        static func load(_ url: URL) async -> CatalogHomeBackdropModel.Layer? {
            let resource = ArtworkResource.url(url)
            guard let image = await ArtworkResourceView.image(for: resource) else { return nil }
            // Reuse decoded artwork and the shared bounded/coalescing palette cache.
            let sampled = await ArtworkProgressPaletteCache.shared.colors(for: resource)
            let surface = CatalogDetailSurfacePalette.surface(from: sampled)
            return CatalogHomeBackdropModel.Layer(url: url, image: image, colors: [surface.color])
        }
    }
#endif
