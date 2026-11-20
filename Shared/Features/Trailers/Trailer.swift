import Foundation
import Observation

nonisolated struct TMDBTrailerVideo: Decodable, Hashable, Sendable {
    let id: String
    let name: String
    let key: String
    let site: String
    let type: String
    let official: Bool
    let iso_639_1: String?
    let size: Int?

    var source: TrailerSource? {
        guard official, type == "Trailer" else { return nil }
        if site == "YouTube", key.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return .youTube(key)
        }
        if site == "Vimeo", key.range(of: "^[0-9]{1,15}$", options: .regularExpression) != nil {
            return .vimeo(key)
        }
        return nil
    }

    static func preferred(_ videos: [Self], language: String) -> [Self] {
        let language = language.components(separatedBy: "-")[0].lowercased()
        return videos.filter { $0.source != nil }.sorted {
            let a = $0.iso_639_1 == language
            let b = $1.iso_639_1 == language
            if a != b {
                return a
            }
            if ($0.size ?? 0) != ($1.size ?? 0) {
                return ($0.size ?? 0) > ($1.size ?? 0)
            }
            return $0.id < $1.id
        }
    }
}

/// A provider must explicitly supply an authorized direct stream and bind it to the catalog title.
/// TMDb's YouTube/Vimeo keys are NOT direct URLs. Never construct this by scraping those providers.
nonisolated struct AuthorizedTrailerStream: Hashable, Sendable {
    let catalogID: String
    let url: URL
    let provider: String
    let permitsAdFreeLooping: Bool

    init?(catalogID: String, url: URL, provider: String, permitsAdFreeLooping: Bool = false) {
        guard url.scheme == "https", let host = url.host?.lowercased(), !provider.isEmpty,
              ["mp4", "m3u8"].contains(url.pathExtension.lowercased()),
              !["youtube.com", "youtube-nocookie.com", "youtu.be", "googlevideo.com", "vimeo.com"].contains(where: {
                  host == $0 || host.hasSuffix("." + $0)
              }) else { return nil }
        self.catalogID = catalogID; self.url = url; self.provider = provider
        self.permitsAdFreeLooping = permitsAdFreeLooping
    }
}

nonisolated enum TrailerSource: Hashable, Sendable {
    case youTube(String), vimeo(String), direct(AuthorizedTrailerStream)

    var externalURL: URL? {
        switch self {
        case let .youTube(id): URL(string: "https://www.youtube.com/watch?v=\(id)")
        case let .vimeo(id): URL(string: "https://vimeo.com/\(id)")
        case .direct: nil
        }
    }

    var supportsInlinePreview: Bool {
        if case .direct = self {
            return true
        }; return false
    }
}

nonisolated struct TrailerSelection: Identifiable, Hashable, Sendable {
    let title: String
    let source: TrailerSource
    var id: String {
        "\(title)|\(source)"
    }
}

nonisolated enum TrailerPreviewPolicy {
    static func allowsAutoplay(
        enabled: Bool,
        visible: Bool,
        active: Bool,
        settled: Bool,
        reduceMotion: Bool,
        lowPower: Bool,
        connected: Bool,
        expensive: Bool,
        constrained: Bool,
        allowsCellular: Bool,
        anotherPlayerActive: Bool,
    ) -> Bool {
        enabled && visible && active && settled && !reduceMotion && !lowPower && connected
            && !constrained && (!expensive || allowsCellular) && !anotherPlayerActive
    }
}

/// Exclusively owns trailer audio without touching Simkl, resume records or the feature player's media session.
@MainActor @Observable
final class TrailerPlaybackCoordinator {
    static let shared = TrailerPlaybackCoordinator()
    private var featureOwners: Set<UUID> = []
    private var trailerOwner: UUID?
    private var stopTrailer: (() -> Void)?
    private(set) var manualTrailerActive = false
    var featurePlaybackActive: Bool {
        !featureOwners.isEmpty
    }

    func claim(_ owner: UUID, manual: Bool, stop: @escaping () -> Void) -> Bool {
        guard !featurePlaybackActive, manual || !manualTrailerActive else { return false }
        let previous = stopTrailer
        trailerOwner = nil; stopTrailer = nil; manualTrailerActive = false
        previous?()
        trailerOwner = owner; stopTrailer = stop; manualTrailerActive = manual
        return true
    }

    func release(_ owner: UUID) {
        guard trailerOwner == owner else { return }
        trailerOwner = nil; stopTrailer = nil; manualTrailerActive = false
    }

    func beginFeature(_ owner: UUID) {
        featureOwners.insert(owner)
        let stop = stopTrailer
        trailerOwner = nil; stopTrailer = nil; manualTrailerActive = false
        stop?()
    }

    func endFeature(_ owner: UUID) {
        featureOwners.remove(owner)
    }
}
