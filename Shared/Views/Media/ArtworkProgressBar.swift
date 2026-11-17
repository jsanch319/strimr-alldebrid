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

    /// At least 4.5:1 against the lightest possible composited track, even over white artwork.
    var legible: Self {
        var result = self
        for _ in 0 ..< 24 where result.luminance < 0.36 {
            result = Self(red: result.red * 0.9 + 0.1, green: result.green * 0.9 + 0.1, blue: result.blue * 0.9 + 0.1)
        }
        return result
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
        var ranked: [(key: Int, color: ProgressArtworkColor, score: Double)] = []
        for (key, bucket) in buckets {
            let count = Double(bucket.count)
            let color = ProgressArtworkColor(
                red: bucket.red / count,
                green: bucket.green / count,
                blue: bucket.blue / count,
            )
            let high: Double = max(color.red, max(color.green, color.blue))
            let low: Double = min(color.red, min(color.green, color.blue))
            let saturation: Double = high > 0 ? (high - low) / high : 0
            let vibrance: Double = (0.12 + saturation * 2) * (0.4 + high)
            let score: Double = count.squareRoot() * vibrance
            ranked.append((key: key, color: color, score: score))
        }
        ranked.sort { left, right in
            if left.score == right.score {
                return left.key < right.key
            }
            return left.score > right.score
        }
        var selected: [ProgressArtworkColor] = []
        for candidate in ranked {
            guard selected.allSatisfy({ abs($0.red - candidate.color.red) + abs($0.green - candidate.color.green)
                    + abs($0.blue - candidate.color.blue) > 0.3 }) else { continue }
            selected.append(candidate.color)
            if selected.count == 3 {
                break
            }
        }
        guard !selected.isEmpty else { return [] }
        if selected.count == 1 {
            selected.append(selected[0])
        } // Monochrome artwork keeps its own hue.
        return selected.map(\.legible)
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
        loadedResource == resource && !colors.isEmpty ? colors.map(\.color) : [.white, .white.opacity(0.9)]
    }

    var body: some View {
        Capsule().fill(.black.opacity(contrast == .increased ? 0.95 : 0.82))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(LinearGradient(colors: palette, startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * ArtworkProgressSampler.fraction(progress))
                        .shadow(color: palette[0].opacity(0.22), radius: 2)
                }
            }
            .overlay { Capsule().strokeBorder(.white.opacity(contrast == .increased ? 0.7 : 0.4), lineWidth: 0.5) }
            .frame(height: contrast == .increased ? 6 : 5.5)
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
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
