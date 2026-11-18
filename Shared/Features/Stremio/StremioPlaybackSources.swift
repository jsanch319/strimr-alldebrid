import Foundation

/// Public source labels contain no remote URLs, configuration, raw add-on titles or credentials.
nonisolated struct StremioSourceLabel: Identifiable, Hashable, Sendable {
    let id: String
    let filename: String
    let quality: Int
}

@MainActor
final class StremioPlaybackSources {
    private struct Entry {
        let label: StremioSourceLabel
        let link: String
        let direct: Bool
        var submitted = false
    }

    private let client: any StremioClientProtocol
    private let store: any StremioConfigurationStorage
    private var entries: [Entry] = []
    private var cachedIdentity: String?
    private var cachedAt: Date?
    private var configuration: StremioConfiguration?
    private(set) var configured = false

    init(
        client: any StremioClientProtocol = StremioClient(),
        store: (any StremioConfigurationStorage)? = nil,
    ) {
        self.client = client; self.store = store ?? StremioConfigurationStore()
    }

    static func identity(title: TMDBTitle, episode: TMDBEpisode?) throws -> (type: String, id: String) {
        guard let imdb = title.matchingIDs.imdb,
              imdb.range(of: #"^tt\d{5,12}$"#, options: .regularExpression) != nil
        else { throw StremioError.missingIMDb }
        if title.kind == .movie {
            return ("movie", imdb)
        }
        guard let episode, episode.season_number >= 0,
              episode.episode_number > 0 else { throw CatalogSourceResolver.Failure.chooseEpisode }
        return ("series", "\(imdb):\(episode.season_number):\(episode.episode_number)")
    }

    func discover(title: TMDBTitle, episode: TMDBEpisode?) async throws -> [AllDebridTitleMatcher.Source] {
        if configuration == nil {
            configuration = try store.load()
        }
        guard let configuration, configuration.authorized else { configured = false; return [] }
        configured = true
        let identity = try Self.identity(title: title, episode: episode)
        let key = "\(title.kind):\(title.id):\(identity.id)"
        if cachedIdentity != key || cachedAt == nil || Date().timeIntervalSince(cachedAt!) >= 60 {
            entries = []; cachedIdentity = key; cachedAt = nil
            let manifest = try await client.manifest(configuration)
            guard manifest.supports(identity.type, id: identity.id) else { throw StremioError.unsupportedManifest }
            let streams = try await client.streams(configuration, type: identity.type, id: identity.id)
            try Task.checkCancellation()
            cachedAt = Date()
            var seen = Set<String>()
            for stream in streams {
                guard stream.behaviorHints?.proxyHeaders?.isEmpty != false else { continue }
                let filename = stream.behaviorHints?.filename
                if let filename,
                   !AuthorizedSourceCandidate.matchesFile(filename, title: title, episode: episode)
                {
                    continue
                }
                let link: String
                let direct: Bool
                if let raw = stream.url, AuthorizedSourceCandidate.validLink(raw) {
                    link = raw; direct = URL(string: raw)?.scheme?.lowercased() == "https"
                    // Browser/hoster links use AllDebrid, not the native player's URL path.
                } else if let hash = stream.infoHash, hash.range(
                              of: #"^[a-fA-F0-9]{40}$"#,
                              options: .regularExpression,
                          ) != nil,
                          let filename,
                          AuthorizedSourceCandidate.matchesFile(filename, title: title, episode: episode)
                {
                    var c = URLComponents(); c.scheme = "magnet"
                    c.queryItems = [
                        URLQueryItem(name: "xt", value: "urn:btih:" + hash),
                        URLQueryItem(name: "dn", value: filename),
                    ]
                    guard let raw = c.string else { continue }; link = raw; direct = false
                } else {
                    continue
                }
                guard seen.insert(link).inserted else { continue }
                let quality = AllDebridTitleMatcher
                    .resolution([stream.name, stream.title, stream.displayDetails, filename].compactMap(\.self)
                        .joined(separator: " "))
                let name = title
                    .displayTitle + (episode.map { " · S\($0.season_number) E\($0.episode_number)" } ?? "") + " · \(quality > 0 ? String(quality) + "p" : "Original")"
                entries.append(Entry(
                    label: .init(id: UUID().uuidString, filename: name, quality: quality),
                    link: link,
                    direct: direct,
                ))
            }
        }
        return AllDebridTitleMatcher.ranked(entries.filter { !$0.submitted }.map { .stremio($0.label) })
    }

    func resolve(
        _ label: StremioSourceLabel,
        acquisition: CatalogSourceAcquisition?,
        title: TMDBTitle,
        episode: TMDBEpisode?,
    ) async throws -> URL {
        guard let index = entries.firstIndex(where: { $0.label == label }),
              !entries[index].submitted else { throw StremioError.playback }
        let entry = entries[index]
        try Task.checkCancellation()
        if entry.direct, let url = URL(string: entry.link) {
            do {
                let ready = try await client.playbackURL(url)
                try Task.checkCancellation()
                return ready
            } catch {
                if error.isCancellation {
                    throw CancellationError()
                }
            }
            // A compatible hoster page can instead be unlocked through the documented AllDebrid API.
        }
        guard let acquisition else { throw StremioError.unsupportedSource }
        do {
            try await acquisition.submitUserLink(entry.link, title: title, episode: episode)
            try Task.checkCancellation()
            guard entries.indices.contains(index), entries[index].label == label else { throw CancellationError() }
            entries[index].submitted = true
            throw CatalogSourceResolver.Failure
                .processing("Checking the authorized add-on source in AllDebrid. Availability refreshes automatically.")
        } catch {
            if error.isCancellation {
                throw CancellationError()
            }
            if case CatalogSourceResolver.Failure.processing = error {
                throw error
            }
            if AllDebridAPIClient.isAuthenticationOrRateLimit(error) {
                throw error
            }
            throw StremioError.playback
        }
    }
}
