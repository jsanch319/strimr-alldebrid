import Foundation
@testable import Strimr
import Testing

struct ArtworkProgressTests {
    private func pixels(_ colors: [[UInt8]]) -> [UInt8] {
        colors.flatMap { color in Array(repeating: color + [255], count: 100).flatMap(\.self) }
    }

    @Test func `light dark colorful and monochrome palettes remain visible without invented hues`() {
        for source in [[[UInt8(250), 240, 220]], [[5, 10, 20]], [[230, 20, 30], [20, 80, 230], [230, 170, 20]]] {
            let colors = ArtworkProgressSampler.colors(pixels: pixels(source))
            #expect((2 ... 3).contains(colors.count))
            #expect(colors.allSatisfy { $0.luminance >= 0.36 })
            // Validate all interpolated gradient stops against the track composited over white (worst case).
            for pair in zip(colors, colors.dropFirst()) {
                for step in 0 ... 10 {
                    let fraction = Double(step) / 10
                    let mixed = ProgressArtworkColor(
                        red: pair.0.red * (1 - fraction) + pair.1.red * fraction,
                        green: pair.0.green * (1 - fraction) + pair.1.green * fraction,
                        blue: pair.0.blue * (1 - fraction) + pair.1.blue * fraction,
                    )
                    let track = ProgressArtworkColor(red: 0.18, green: 0.18, blue: 0.18)
                    #expect((mixed.luminance + 0.05) / (track.luminance + 0.05) >= 3)
                }
            }
        }
        let red = ArtworkProgressSampler.colors(pixels: pixels([[200, 15, 10]]))
        #expect(red.allSatisfy { $0.red > $0.green && $0.red > $0.blue })
        #expect(ArtworkProgressSampler.colors(pixels: [0, 0, 0, 0]).isEmpty)
        #expect(ArtworkProgressSampler.colors(pixels: []).isEmpty)
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
