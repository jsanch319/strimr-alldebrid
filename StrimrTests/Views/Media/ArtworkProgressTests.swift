import Foundation
@testable import Strimr
import Testing

struct ArtworkProgressTests {
    private func pixels(_ colors: [[UInt8]]) -> [UInt8] {
        colors.flatMap { color in Array(repeating: color + [255], count: 100).flatMap(\.self) }
    }

    @Test func `light dark colorful and monochrome palettes keep source hues without excessive brightening`() {
        let sources: [[[UInt8]]] = [[[250, 240, 220]], [[5, 10, 20]], [[230, 20, 30], [20, 80, 230], [230, 170, 20]]]
        for source in sources {
            let colors = ArtworkProgressSampler.colors(pixels: pixels(source))
            #expect((2 ... 3).contains(colors.count))
            let originals = source.map {
                ProgressArtworkColor(red: Double($0[0]) / 255, green: Double($0[1]) / 255, blue: Double($0[2]) / 255)
            }
            for color in colors {
                #expect(originals.contains { original in
                    let differences = [
                        color.red - original.red,
                        color.green - original.green,
                        color.blue - original.blue,
                    ]
                    return differences.allSatisfy { $0 >= -0.000001 && $0 <= 0.24 }
                        && color.saturation <= original.saturation + 0.000001
                })
            }
        }
        let red = ArtworkProgressSampler.colors(pixels: pixels([[200, 15, 10]]))
        #expect(red.allSatisfy { $0.red > $0.green && $0.red > $0.blue })
        #expect(ArtworkProgressSampler.colors(pixels: [0, 0, 0, 0]).isEmpty)
        #expect(ArtworkProgressSampler.colors(pixels: []).isEmpty)
    }

    @Test func `normal thumbnail colors remain exact and dark colors receive only a bounded lift`() {
        let warm = ProgressArtworkColor(red: 0.8, green: 0.45, blue: 0.2)
        #expect(warm.legible == warm)
        let dark = ProgressArtworkColor(red: 0.02, green: 0.04, blue: 0.08)
        #expect(dark.legible.luminance > dark.luminance)
        #expect(dark.legible.maximum < 0.4)
        #expect(dark.legible.saturation <= dark.saturation)
        #expect(dark.legible.red < dark.legible.green && dark.legible.green < dark.legible.blue)
    }

    @Test func `gray backgrounds cannot crowd out distinct saturated artwork accents`() {
        let gray = Array(repeating: [UInt8](arrayLiteral: 140, 150, 155, 255), count: 1000).flatMap(\.self)
        let red = Array(repeating: [UInt8](arrayLiteral: 110, 10, 5, 255), count: 50).flatMap(\.self)
        let blue = Array(repeating: [UInt8](arrayLiteral: 5, 20, 110, 255), count: 50).flatMap(\.self)
        let palette = ArtworkProgressSampler.colors(pixels: gray + red + blue)
        #expect(palette.contains { $0.red > $0.blue + 0.2 })
        #expect(palette.contains { $0.blue > $0.red + 0.2 })
        #expect(palette.allSatisfy { $0.maximum < 0.7 })
    }

    @Test func `thin progress accents brighten muddy colors without changing title hues`() {
        let artwork = [
            ProgressArtworkColor(red: 0.18, green: 0.40, blue: 0.52),
            ProgressArtworkColor(red: 0.40, green: 0.30, blue: 0.20),
            ProgressArtworkColor(red: 0.38, green: 0.08, blue: 0.06),
            ProgressArtworkColor(red: 0.70, green: 0.65, blue: 0.50),
        ]
        let accents = artwork.map(\.progressAccent)
        #expect(Set(accents).count == artwork.count)
        for (source, accent) in zip(artwork, accents) {
            #expect(accent.maximum >= 0.90 && accent.maximum <= 0.98)
            #expect(accent.saturation >= 0.65 - 0.000001)
            #expect(accent.saturation <= 0.95 + 0.000001)
            #expect(abs((accent.hue ?? -1) - (source.hue ?? -1)) < 0.000001)
            #expect([accent.red, accent.green, accent.blue].allSatisfy { (0 ... 1).contains($0) })
        }
        #expect(accents[0].blue > accents[0].red) // Series artwork stays blue/cyan.
        #expect(accents[1].red > accents[1].blue) // Warm movie artwork cannot become blue.
    }

    @Test func `monochrome artwork stays neutral and bright source colors are not washed out`() {
        for level in [0.0, 0.2, 0.6, 1.0] {
            let accent = ProgressArtworkColor(red: level, green: level, blue: level).progressAccent
            #expect(accent.red == accent.green && accent.green == accent.blue)
            #expect(accent.maximum >= 0.9)
        }
        let bright = ProgressArtworkColor(red: 0.95, green: 0.3, blue: 0.2)
        #expect(abs(bright.progressAccent.maximum - bright.maximum) < 0.000001)
        #expect(abs(bright.progressAccent.saturation - bright.saturation) < 0.000001)
    }

    @Test func `progress width keeps exact local or remote fraction and bounds invalid values`() {
        #expect(ArtworkProgressSampler.fraction(7200.5 / 10020) == 7200.5 / 10020)
        #expect(ArtworkProgressSampler.fraction(0.37) == 0.37)
        #expect(ArtworkProgressSampler.fraction(-0.2) == 0)
        #expect(ArtworkProgressSampler.fraction(1.2) == 1)
        #expect(ArtworkProgressSampler.fraction(.nan) == 0)
        #expect(ArtworkProgressSampler.fraction(.infinity) == 0)
    }

    private actor Loader {
        var calls = 0
        func load(_ resource: ArtworkResource) async -> [ProgressArtworkColor] {
            calls += 1
            try? await Task.sleep(for: .milliseconds(20))
            return [.init(red: resource == .data(Data([1])) ? 1 : 0.5, green: 0.8, blue: 0.8)]
        }

        func count() -> Int {
            calls
        }
    }

    @Test func `palette cache coalesces requests distinguishes artwork and bounds retained entries`() async {
        let loader = Loader()
        let cache = ArtworkProgressPaletteCache(capacity: 1, loader: { await loader.load($0) })
        let first = ArtworkResource.data(Data([1])), second = ArtworkResource.data(Data([2]))
        async let a = cache.colors(for: first)
        async let b = cache.colors(for: first)
        let both = await (a, b)
        #expect(both.0 == both.1)
        #expect(await loader.count() == 1)
        #expect(await cache.colors(for: first) == both.0)
        #expect(await loader.count() == 1)
        let changed = await cache.colors(for: second)
        #expect(changed != both.0)
        #expect(await loader.count() == 2)
        _ = await cache.colors(for: first)
        #expect(await loader.count() == 3)
    }
}
