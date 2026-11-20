import CoreGraphics
import SwiftUI

/// Numeric sRGB swatches keep sampling/cache work independent of SwiftUI and the main actor.
nonisolated struct ProgressArtworkColor: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    var maximum: Double {
        max(red, max(green, blue))
    }

    var saturation: Double {
        maximum > 0 ? (maximum - min(red, min(green, blue))) / maximum : 0
    }

    var hue: Double? {
        let delta = maximum - min(red, min(green, blue))
        guard delta > 0.01, saturation >= 0.2 else { return nil }
        var value: Double = if maximum == red {
            (green - blue) / delta
        } else if maximum == green {
            (blue - red) / delta + 2
        } else {
            (red - green) / delta + 4
        }
        if value < 0 {
            value += 6
        }
        return value / 6
    }

    func distance(to other: Self) -> Double {
        abs(red - other.red) + abs(green - other.green) + abs(blue - other.blue)
    }

    /// Presentation-only emphasis for a thin progress fill. Keep the sampled hue while
    /// lifting value and restoring chroma; never alter the cached artwork/detail palette.
    var progressAccent: Self {
        let minimum = min(red, min(green, blue))
        let delta = maximum - minimum
        let value = min(0.98, max(0.90, maximum))
        guard delta > 0.000001 else { return Self(red: value, green: value, blue: value) }
        // Nearly neutral artwork stays neutral instead of acquiring an invented accent.
        let targetSaturation = saturation >= 0.10 ? min(0.95, max(0.65, saturation)) : saturation
        func channel(_ component: Double) -> Double {
            value * (1 - targetSaturation + targetSaturation * (component - minimum) / delta)
        }
        return Self(red: channel(red), green: channel(green), blue: channel(blue))
    }

    /// Keep the source hue/value; only lift very dark swatches slightly so their fill stays distinguishable.
    /// Unlike value normalization, this bounded white mix never boosts saturation or turns shadows neon.
    var legible: Self {
        let lift = min(0.24, max(0, (0.08 - luminance) * 3))
        return Self(
            red: red + (1 - red) * lift,
            green: green + (1 - green) * lift,
            blue: blue + (1 - blue) * lift,
        )
    }
}

nonisolated enum ArtworkProgressSampler {
    @concurrent static func colors(from image: CGImage) async -> [ProgressArtworkColor] {
        let side = 40
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return colors(pixels: pixels)
    }

    static func colors(pixels: [UInt8]) -> [ProgressArtworkColor] {
        struct Bucket { var count = 0; var red = 0.0; var green = 0.0; var blue = 0.0 }
        var buckets: [Int: Bucket] = [:]
        for offset in stride(from: 0, to: pixels.count - pixels.count % 4, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha >= 0.5 else { continue }
            let r = min(1, Double(pixels[offset]) / 255 / alpha)
            let g = min(1, Double(pixels[offset + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[offset + 2]) / 255 / alpha)
            let key = (Int(r * 15) << 8) | (Int(g * 15) << 4) | Int(b * 15)
            var bucket = buckets[key, default: Bucket()]
            bucket.count += 1; bucket.red += r; bucket.green += g; bucket.blue += b
            buckets[key] = bucket
        }
        struct Candidate { let key: Int; let color: ProgressArtworkColor; let score: Double; let count: Int }
        var ranked: [Candidate] = []
        for (key, bucket) in buckets {
            let count = Double(bucket.count)
            let color = ProgressArtworkColor(
                red: bucket.red / count,
                green: bucket.green / count,
                blue: bucket.blue / count,
            )
            let saturation = color.saturation
            let vibrance: Double = (0.05 + saturation * saturation * 3) * (0.4 + color.maximum)
            let population: Double = count.squareRoot().squareRoot()
            let score: Double = population * vibrance
            ranked.append(Candidate(key: key, color: color, score: score, count: bucket.count))
        }
        ranked.sort { left, right in
            if left.score == right.score {
                return left.key < right.key
            }
            return left.score > right.score
        }
        // Gray sky/walls must not crowd out a title's red cape, blue suit or other vibrant accents.
        let rich = ranked.filter { $0.color.saturation >= 0.3 && $0.color.maximum > 0.12 && $0.count >= 2 }
        let richPixels = rich.reduce(0) { $0 + $1.count }
        let totalPixels = buckets.values.reduce(0) { $0 + $1.count }
        let candidates = richPixels >= max(6, totalPixels / 100) ? rich : ranked
        var selected: [ProgressArtworkColor] = []
        for candidate in candidates {
            let distinctHue = selected.allSatisfy { existing in
                guard let left = existing.hue, let right = candidate.color.hue else { return false }
                let difference = abs(left - right)
                return min(difference, 1 - difference) >= 0.09
            }
            guard selected.isEmpty || distinctHue else { continue }
            selected.append(candidate.color)
            if selected.count == 3 {
                break
            }
        }
        // Artwork with one or two hues can still supply different source shades; never invent unrelated hues.
        for candidate in candidates where selected.count < 3 {
            guard selected.allSatisfy({ $0.distance(to: candidate.color) > 0.3 }) else { continue }
            selected.append(candidate.color)
        }
        guard !selected.isEmpty else { return [] }
        if selected.count == 1 {
            selected.append(selected[0])
        } // Monochrome artwork keeps its own hue.
        return selected.map(\.legible)
    }

    /// Use the thumbnail's strongest sampled accent, with two same-hue brightness stops.
    /// Blending complementary sampled hues can otherwise create a muddy gray midpoint.
    static func fillColors(_ sampled: [ProgressArtworkColor]) -> [ProgressArtworkColor] {
        guard let source = sampled.first else { return [] }
        let accent = source.progressAccent
        let scale = 0.98 / accent.maximum
        return [accent, ProgressArtworkColor(
            red: accent.red * scale,
            green: accent.green * scale,
            blue: accent.blue * scale,
        )]
    }

    static func fraction(_ progress: Double) -> Double {
        progress.isFinite ? min(max(progress, 0), 1) : 0
    }
}

actor ArtworkProgressPaletteCache {
    static let shared = ArtworkProgressPaletteCache()
    private var cached: [ArtworkResource: [ProgressArtworkColor]] = [:]
    private var order: [ArtworkResource] = []
    private var pending: [ArtworkResource: Task<[ProgressArtworkColor], Never>] = [:]
    private let capacity: Int
    private let loader: @Sendable (ArtworkResource) async -> [ProgressArtworkColor]

    init(capacity: Int = 256, loader: @escaping @Sendable (ArtworkResource) async -> [ProgressArtworkColor] = {
        await ArtworkResourceView.progressColors(for: $0)
    }) {
        self.capacity = max(1, capacity); self.loader = loader
    }

    func colors(for resource: ArtworkResource) async -> [ProgressArtworkColor] {
        if let colors = cached[resource] {
            return colors
        }
        if let task = pending[resource] {
            return await task.value
        }
        let task = Task { await loader(resource) }
        pending[resource] = task
        let colors = await task.value
        pending[resource] = nil
        // Failed images retry on a future appearance, rather than permanently caching a fallback.
        if !colors.isEmpty {
            cached[resource] = colors; order.append(resource)
            if order.count > capacity {
                cached.removeValue(forKey: order.removeFirst())
            }
        }
        return colors
    }
}

nonisolated struct ProgressArtworkPreference: PreferenceKey {
    static var defaultValue: ArtworkResource? {
        nil
    }

    static func reduce(value: inout ArtworkResource?, nextValue: () -> ArtworkResource?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Applied to the artwork itself, so the palette follows the resolved image including spoiler preferences.
    func artworkProgress(_ progress: Double?, hidePercentage: Bool = false, inset: CGFloat = 10) -> some View {
        modifier(ArtworkProgressOverlay(progress: progress, hidePercentage: hidePercentage, inset: inset))
    }
}

private struct ArtworkProgressOverlay: ViewModifier {
    let progress: Double?
    let hidePercentage: Bool
    let inset: CGFloat
    @State private var resource: ArtworkResource?
    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ProgressArtworkPreference.self) { resource = $0 }
            .overlay(alignment: .bottom) {
                if let progress {
                    #if os(iOS)
                        ArtworkMatchedProgressBar(progress: progress, resource: resource)
                            .accessibilityHidden(hidePercentage)
                            .padding(.horizontal, inset).padding(.bottom, inset)
                    #else
                        CardProgressBar(progress: progress)
                            .padding(.horizontal, inset).padding(.bottom, inset)
                    #endif
                }
            }
    }
}

struct ArtworkMatchedProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let progress: Double
    let resource: ArtworkResource?
    @State private var loadedResource: ArtworkResource?
    @State private var colors: [ProgressArtworkColor] = []
    private var palette: [Color] {
        loadedResource == resource && !colors.isEmpty
            ? ArtworkProgressSampler.fillColors(colors).map(\.color) : [.white, .white]
    }

    var body: some View {
        Capsule().fill(.black.opacity(contrast == .increased ? 0.40 : 0.35))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(LinearGradient(colors: palette, startPoint: .leading, endPoint: .trailing))
                        // Opaque fill keeps its artwork hue vivid over the dark artwork scrim.
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(contrast == .increased ? 0.4 : 0.10), lineWidth: 0.5)
                        }
                        .frame(width: proxy.size.width * ArtworkProgressSampler.fraction(progress))
                }
            }
            .overlay { Capsule().strokeBorder(.white.opacity(contrast == .increased ? 0.25 : 0.10), lineWidth: 0.5) }
            .frame(height: contrast == .increased ? 5.5 : 5)
            .shadow(color: .black.opacity(0.18), radius: 0.75, y: 0.35)
            .transaction {
                if reduceMotion {
                    $0.disablesAnimations = true
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback progress")
            .accessibilityValue(Text(ArtworkProgressSampler.fraction(progress), format: .percent))
            .task(id: resource) {
                guard let resource else { loadedResource = nil; colors = []; return }
                let result = await ArtworkProgressPaletteCache.shared.colors(for: resource)
                guard !Task.isCancelled else { return }
                colors = result; loadedResource = resource
            }
    }
}
